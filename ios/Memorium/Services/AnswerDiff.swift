import Foundation

/// Word-by-word comparison of a transcription against what was actually said.
///
/// Only for dictation. Being told "close" after writing down a sentence you
/// half-heard is not feedback: the whole question is *which* word you missed,
/// and that answer is a string comparison rather than anything that needs a
/// model or a connection.
///
/// Deliberately not used for translations. A translation has many correct
/// forms, so marking one word by word against a single reference would flag
/// perfectly good wording as a mistake -- there the judgement belongs to a
/// grader that understands meaning.
enum AnswerDiff {
    enum State: Equatable, Sendable {
        /// The learner wrote this word.
        case matched
        /// It was said, and they didn't write it.
        case missed
    }

    struct Token: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let state: State

        var isMissed: Bool { state == .missed }
    }

    struct Result: Equatable, Sendable {
        /// What was said, each word marked as caught or missed.
        let expected: [Token]
        /// Words the learner wrote that were never said. Worth showing: a
        /// mishearing is a swap, and only seeing the missing half of it makes
        /// it look like an omission.
        let extras: [String]

        var isPerfect: Bool { !expected.contains(where: \.isMissed) && extras.isEmpty }
    }

    /// Compare a transcription against the sentence that was spoken.
    ///
    /// Words are matched on the same normalised form the grader uses, so an
    /// accent someone's keyboard cannot produce doesn't read as a missed word
    /// -- but the original spelling is what comes back, because seeing the
    /// sentence as it is really written is the point of the exercise.
    static func compare(expected: String, given: String) -> Result {
        let expectedWords = words(in: expected)
        let givenWords = words(in: given)

        let expectedKeys = expectedWords.map(key)
        let givenKeys = givenWords.map(key)
        let pairs = longestCommonSubsequence(expectedKeys, givenKeys)

        let caught = Set(pairs.map(\.0))
        let used = Set(pairs.map(\.1))

        return Result(
            expected: expectedWords.enumerated().map { index, word in
                Token(id: index, text: word, state: caught.contains(index) ? .matched : .missed)
            },
            extras: givenWords.enumerated()
                .filter { !used.contains($0.offset) && !key($0.element).isEmpty }
                .map(\.element)
        )
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func key(_ word: String) -> String {
        // Articles stay: in a dictation, dropping one is the mistake.
        LocalGrader.normalise(word, droppingArticles: false)
    }

    /// Indices of the words that line up, in order.
    ///
    /// A subsequence rather than a positional comparison, so one extra or
    /// missing word near the start doesn't mark the whole rest of the sentence
    /// wrong -- which is exactly the mistake a dictation produces most often.
    private static func longestCommonSubsequence(
        _ a: [String], _ b: [String]
    ) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = Array(
            repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1
        )
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] =
                    a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
