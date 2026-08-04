import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

enum AnswerVerdict: String, Sendable {
    case correct, close, wrong
}

struct Judgement: Sendable {
    let verdict: AnswerVerdict
    let reason: String
    let source: Source

    enum Source: String, Sendable {
        case exact = "matched"
        case onDevice = "on-device"
        case server = "Claude"
    }
}

/// Grades a typed answer through three tiers, cheapest first.
///
/// 1. Normalised string match  -- instant, offline, free. Handles most answers.
/// 2. Apple Foundation Models  -- instant, offline, free. Judges synonyms and
///    near-misses. Absent on devices without Apple Intelligence.
/// 3. The server (Claude)      -- last resort, needs a connection.
///
/// Tier 2 is skipped entirely when the device can't run it, so the app behaves
/// correctly on an older iPhone rather than failing to grade at all.
@MainActor
final class LocalGrader {
    private let client: APIClient?
    private let sourceLang: String
    private let targetLang: String

    init(client: APIClient?, sourceLang: String, targetLang: String) {
        self.client = client
        self.sourceLang = sourceLang
        self.targetLang = targetLang
    }

    // MARK: - Tier 1

    /// Fold case, strip diacritics and punctuation, drop a leading article.
    ///
    /// Accent-insensitivity is deliberate at this tier: a missing accent on a
    /// phone keyboard is a typing slip, not a vocabulary failure. Tier 2 still
    /// sees the raw text and can comment on it.
    /// Characters that Unicode does not decompose into base + diacritic, so
    /// `.diacriticInsensitive` folding leaves them untouched.
    ///
    /// Without these, a Norwegian learner typing "lope" for "løpe" misses the
    /// fast path entirely -- and someone who hasn't installed the Norwegian
    /// keyboard has no easy way to type ø or å at all. That is precisely the
    /// typing-slip case this tier exists to absorb. The later tiers still see
    /// the raw text and can point out the correct spelling.
    nonisolated private static let nonDecomposing: [Character: String] = [
        "ø": "o", "æ": "ae", "å": "a",  // Norwegian, Danish, Swedish
        "ß": "ss",  // German
        "ł": "l",  // Polish
        "đ": "d", "ð": "d", "þ": "th",  // Croatian, Icelandic
        "ı": "i",  // Turkish dotless i
    ]

    /// - Parameter droppingArticles: leave this off for a dictation, where a
    ///   missing article is the mistake being tested rather than a slip to
    ///   forgive. Everywhere else "el perro" and "perro" are the same answer.
    nonisolated static func normalise(_ text: String, droppingArticles: Bool = true) -> String {
        let transliterated = String(
            text.lowercased().flatMap { character -> String in
                nonDecomposing[character] ?? String(character)
            }
        )
        let lowered = transliterated.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: .current
        )
        let stripped = lowered.components(
            separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted
        ).joined()
        let words = stripped.split(whereSeparator: \.isWhitespace).map(String.init)
        let articles: Set<String> = [
            "the", "a", "an",
            "el", "la", "los", "las", "un", "una",
            "le", "les", "un", "une",
            "der", "die", "das", "ein", "eine",
            "o", "os", "as", "um", "uma",
            "il", "lo", "gli", "uno",
            "de", "het", "een",
        ]
        let meaningful =
            droppingArticles && words.count > 1
                ? Array(words.drop { articles.contains($0) })
                : words
        return meaningful.joined(separator: " ")
    }

    nonisolated private func exactMatch(
        expected: String, given: String, kind: GradeKind
    ) -> Bool {
        let dictation = kind == .dictation
        let e = Self.normalise(expected, droppingArticles: !dictation)
        let g = Self.normalise(given, droppingArticles: !dictation)
        guard !e.isEmpty, !g.isEmpty else { return false }
        if e == g { return true }
        // A word's expected side may list alternatives: "dog / hound". A
        // sentence's may not -- its commas are punctuation, and splitting on
        // them would accept half a sentence.
        guard kind == .word else { return false }
        return e.components(separatedBy: CharacterSet(charactersIn: "/,;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(g)
    }

    // MARK: - Tier 2

    static var onDeviceAvailability: String? {
        #if canImport(FoundationModels)
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is turned off in Settings."
                case .modelNotReady:
                    return "The on-device model is still downloading."
                @unknown default:
                    return "The on-device model is unavailable."
                }
            @unknown default:
                return "The on-device model is unavailable."
            }
        #else
            return "Built without Foundation Models."
        #endif
    }

    /// The rubric for what was actually asked. Mirrors `prompts.grade_system`
    /// on the server, so a tier-2 verdict and a tier-3 verdict mean the same
    /// thing -- otherwise the same answer is right or wrong depending on
    /// whether the phone happens to run Apple Intelligence.
    nonisolated static func instructions(for kind: GradeKind) -> String {
        switch kind {
        case .word:
            """
            You grade a language learner's answer. Be fair, not pedantic.
            Accept synonyms, valid alternative word order, and regional variants.
            Mark "close" when the meaning is right but the form is wrong \
            (gender, conjugation, a misspelling that changes the word).
            Mark "wrong" when the meaning differs.
            Keep the reason to one short sentence, written to the learner.
            """
        case .sentence:
            """
            You grade a learner's translation of a whole sentence. You are \
            judging whether they said the same thing, not whether they matched \
            a reference: different word order, synonyms, contractions and \
            regional variants are all correct. Punctuation and capitalisation \
            are not graded.
            Mark "close" when the meaning came through but something is wrong \
            (tense, agreement, gender, a misspelling that makes another word).
            Mark "wrong" when the meaning differs, a negation is missing, or \
            most of the sentence is absent.
            Keep the reason to one short sentence, quoting the words at fault \
            and giving the form they should have used.
            """
        case .dictation:
            """
            You grade a dictation: the learner heard a sentence and wrote down \
            what they heard, in the same language. There is one right answer \
            and the wording is the point -- never accept a paraphrase.
            Mark "correct" when every word is there, in order, ignoring \
            punctuation, capitalisation, and accents their keyboard makes hard \
            to type.
            Mark "close" when one or two words are misheard, misspelled or \
            dropped and the sentence is otherwise intact.
            Mark "wrong" when several words are wrong or missing.
            Keep the reason to one short sentence naming the words that differ \
            and what was actually said.
            """
        }
    }

    private func onDeviceJudgement(
        prompt: String, expected: String, given: String, kind: GradeKind
    ) async -> Judgement? {
        #if canImport(FoundationModels)
            guard Self.onDeviceAvailability == nil else { return nil }
            let instructions = Self.instructions(for: kind)
            do {
                let session = LanguageModelSession(instructions: instructions)
                // A dictation has nothing on screen to quote, and inventing a
                // "shown" line would tell the model the learner could read it.
                let shown =
                    kind == .dictation
                        ? "They heard it spoken aloud, with nothing on screen.\n"
                        : (prompt.isEmpty ? "" : "They were shown: \"\(prompt)\"\n")
                let response = try await session.respond(
                    to: """
                    Target language: \(targetLang). Learner's language: \(sourceLang).
                    \(shown)Expected: "\(expected)"
                    They wrote: "\(given)"
                    """,
                    generating: OnDeviceVerdict.self
                )
                let content = response.content
                let verdict = AnswerVerdict(rawValue: content.verdict.lowercased()) ?? .close
                return Judgement(verdict: verdict, reason: content.reason, source: .onDevice)
            } catch {
                return nil
            }
        #else
            return nil
        #endif
    }

    // MARK: - Entry point

    func judge(
        prompt: String, expected: String, given: String, kind: GradeKind = .word
    ) async -> Judgement {
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Judgement(verdict: .wrong, reason: "Nothing entered.", source: .exact)
        }

        if exactMatch(expected: expected, given: trimmed, kind: kind) {
            return Judgement(
                verdict: .correct,
                reason: kind == .dictation ? "Word for word." : "Exactly right.",
                source: .exact
            )
        }

        if let judgement = await onDeviceJudgement(
            prompt: prompt, expected: expected, given: trimmed, kind: kind
        ) {
            return judgement
        }

        if let client {
            do {
                let response = try await client.gradeAnswer(
                    prompt: prompt, expected: expected, given: trimmed, kind: kind
                )
                return Judgement(
                    verdict: AnswerVerdict(rawValue: response.verdict) ?? .close,
                    reason: response.reason,
                    source: .server
                )
            } catch {
                // Fall through: offline with no on-device model.
            }
        }

        // Every tier declined. Say so plainly rather than guessing "wrong" --
        // a false negative here would punish a correct answer and corrupt the
        // learner's schedule.
        return Judgement(
            verdict: .close,
            reason: "Couldn't check this one automatically — grade it yourself.",
            source: .exact
        )
    }
}

#if canImport(FoundationModels)
    @Generable
    struct OnDeviceVerdict {
        @Guide(description: "One of: correct, close, wrong")
        var verdict: String
        @Guide(description: "One short sentence for the learner")
        var reason: String
    }
#endif
