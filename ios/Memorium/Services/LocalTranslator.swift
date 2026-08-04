import Foundation
#if canImport(Translation)
    import Translation
#endif

/// Whether the device can translate a language pair without asking the server.
enum OnDeviceTranslation: Sendable, Equatable {
    /// The pair is downloaded; translation is offline and free.
    case ready
    /// Apple has the pair but it isn't downloaded yet. Settings offers this.
    case needsDownload
    /// Apple doesn't cover the pair, or the framework isn't there at all.
    /// Carries a sentence for the learner.
    case unsupported(String)
}

/// No tier could answer: nothing on the device, and nothing to ask.
enum TranslatorError: LocalizedError {
    case noTierAvailable

    /// A whole sentence, like the `APIError` cases: it is shown on its own on a
    /// draft row, and after "Couldn't translate: " under the fields.
    var errorDescription: String? {
        switch self {
        case .noTierAvailable:
            "This language pair isn't on the device, and there's no server configured."
        }
    }
}

/// Fills in whichever side of a card was left blank, cheapest source first.
///
/// 1. Apple's on-device translator -- instant, offline, free. Covers whatever
///    language pairs the learner has downloaded.
/// 2. The server (Claude)          -- for pairs Apple doesn't have, and for
///    anything the on-device session declines.
///
/// Tier 1 is the common case, and it changes what the feature costs: a learner
/// on a downloaded pair adds a hundred words without a single request, works on
/// a plane, and doesn't need a server configured at all. Tier 2 exists because
/// Apple's catalogue is smaller than the twenty languages this app offers.
///
/// Deliberately shaped like `LocalGrader`: same ladder, same "return nil to
/// decline" convention, same reasons.
@MainActor
final class LocalTranslator {
    private let client: APIClient?
    private let sourceLang: String
    private let targetLang: String

    init(client: APIClient?, sourceLang: String, targetLang: String) {
        self.client = client
        self.sourceLang = sourceLang
        self.targetLang = targetLang
    }

    // MARK: - Which way round

    /// `into` names the side being *filled*, so the text we were handed is in
    /// the other language. Same swap `translate_prompt` does on the server.
    nonisolated static func languages(
        into direction: TranslationDirection, source: String, target: String
    ) -> (from: String, to: String) {
        direction == .source ? (from: target, to: source) : (from: source, to: target)
    }

    // MARK: - Tier 1

    /// Whether `source` -> `target` can be done on device.
    ///
    /// Availability is per-direction, so a card that gets filled both ways needs
    /// both checked -- see `pairStatus`.
    static func status(from source: String, to target: String) async -> OnDeviceTranslation {
        #if canImport(Translation)
            guard !source.isEmpty, !target.isEmpty else {
                return .unsupported("No language pair chosen yet.")
            }
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target)
            )
            switch status {
            case .installed:
                return .ready
            case .supported:
                return .needsDownload
            case .unsupported:
                return .unsupported("Your device can't translate this pair on its own.")
            @unknown default:
                return .unsupported("Your device can't translate this pair on its own.")
            }
        #else
            return .unsupported("Built without the Translation framework.")
        #endif
    }

    /// The pair as a whole, reported at its weakest direction. A card is filled
    /// in both directions, so "ready one way" is not ready.
    static func pairStatus(source: String, target: String) async -> OnDeviceTranslation {
        let forward = await status(from: source, to: target)
        let back = await status(from: target, to: source)
        for status in [forward, back] {
            if case .unsupported = status { return status }
        }
        return forward == .needsDownload || back == .needsDownload ? .needsDownload : .ready
    }

    /// Translates on device, or returns nil meaning "not me -- try the server".
    ///
    /// Every failure collapses to nil rather than throwing. A pair that isn't
    /// downloaded is not something the learner needs told about mid-word; it
    /// just means the next tier answers, exactly as in `LocalGrader`.
    private func onDeviceTranslation(
        _ text: String, into direction: TranslationDirection
    ) async -> String? {
        #if canImport(Translation)
            let pair = Self.languages(into: direction, source: sourceLang, target: targetLang)
            guard !pair.from.isEmpty, !pair.to.isEmpty else { return nil }
            do {
                let session = TranslationSession(
                    installedSource: Locale.Language(identifier: pair.from),
                    target: Locale.Language(identifier: pair.to)
                )
                let response = try await session.translate(text)
                let translated = response.targetText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty result is a failure dressed as a success; let the
                // server have a go rather than writing a blank into the deck.
                return translated.isEmpty ? nil : translated
            } catch {
                return nil
            }
        #else
            return nil
        #endif
    }

    // MARK: - The ladder

    /// Fills the other side of a card. Throws only when no tier could answer.
    func translate(_ text: String, into direction: TranslationDirection) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslatorError.noTierAvailable }

        if let translated = await onDeviceTranslation(trimmed, into: direction) {
            return translated
        }

        guard let client else { throw TranslatorError.noTierAvailable }
        return try await client.translate(trimmed, into: direction)
    }

    /// Fills a whole screenshot import's worth of blanks.
    ///
    /// The same ladder, applied to a list: everything tier 1 can answer is
    /// answered offline and for nothing, and whatever it declines goes to the
    /// server in *one* request rather than one each. That distinction is the
    /// difference between an import that finishes and one that makes sixty
    /// round trips -- Duolingo prints a translation under only about half the
    /// words it lists, and Apple has no model at all for pairs like Norwegian.
    ///
    /// Never throws: a word that no tier could answer comes back nil, so one
    /// refusal doesn't cost the learner the other ninety-nine translations.
    /// Results line up with `texts` by position.
    func translate(
        _ texts: [String], into direction: TranslationDirection
    ) async -> [String?] {
        var filled: [String?] = []
        var pending: [String] = []
        var pendingSlots: [Int] = []

        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let translated = await onDeviceTranslation(trimmed, into: direction)
            {
                filled.append(translated)
            } else {
                if !trimmed.isEmpty {
                    pendingSlots.append(filled.count)
                    pending.append(trimmed)
                }
                filled.append(nil)
            }
        }

        guard !pending.isEmpty, let client else { return filled }
        guard let translations = try? await client.translateBatch(pending, into: direction) else {
            return filled
        }
        for (slot, translation) in zip(pendingSlots, translations) {
            guard let translation, !translation.isEmpty else { continue }
            filled[slot] = translation
        }
        return filled
    }
}
