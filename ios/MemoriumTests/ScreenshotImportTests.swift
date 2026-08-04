import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Memorium

/// Builds a line the way Vision hands one over: normalised, origin bottom-left.
///
/// `top` and `height` are given in the same normalised units, so a page reads
/// top-down here even though the coordinates count up from the bottom.
private func line(
    _ text: String,
    top: CGFloat,
    left: CGFloat = 0.18,
    width: CGFloat = 0.3,
    height: CGFloat = 0.018,
    confidence: Float = 0.9
) -> TextLine {
    TextLine(
        text: text,
        box: CGRect(x: left, y: 1 - top - height, width: width, height: height),
        confidence: confidence
    )
}

/// Measured off the real screenshots: the space between a word and its own
/// translation, and the space between one row and the next.
private let insideRow: CGFloat = 0.011
private let betweenRows: CGFloat = 0.055
private let wordHeight: CGFloat = 0.018
private let glossHeight: CGFloat = 0.015

/// Lays out rows down the page at the measured spacings. A row is a word plus
/// zero or more translation lines.
private func page(_ rows: [[String]]) -> [TextLine] {
    var lines: [TextLine] = []
    var top: CGFloat = 0.1
    for row in rows {
        for (index, text) in row.enumerated() {
            let isWord = index == 0
            let height = isWord ? wordHeight : glossHeight
            if index > 0 { top += insideRow }
            lines.append(line(text, top: top, height: height))
            top += height
        }
        top += betweenRows
    }
    return lines
}

@Suite("Reading a word list out of a screenshot")
struct WordListLayoutTests {
    @Test("A word with no translation doesn't steal the next word's")
    func glosslessWordKeepsItsPlace() {
        // The failure this whole parser was rewritten for. Duolingo prints a
        // translation under only some words, so the old two-lines-per-row rule
        // paired "bor" with "dyr" -- one word glossed as another -- and every
        // row after it was wrong too.
        let candidates = WordListLayout.candidates(
            from: page([
                ["liten", "small, little"],
                ["bor"],
                ["dyr", "expensive, dear, pricey"],
                ["også", "also, too, as well"],
            ])
        )

        #expect(candidates.map(\.lemma) == ["liten", "bor", "dyr", "også"])
        #expect(
            candidates.map(\.gloss) == [
                "small, little", "", "expensive, dear, pricey", "also, too, as well",
            ]
        )
    }

    @Test("A page where nothing is translated stays one word per row")
    func everyRowGlossless() {
        // There is no gap-inside-a-row on this page at all, so a naive split of
        // the gaps into two halves would invent one and pair the words up.
        let candidates = WordListLayout.candidates(
            from: page([["stor"], ["by"], ["stort"], ["kommer"], ["oslo"]])
        )

        #expect(candidates.map(\.lemma) == ["stor", "by", "stort", "kommer", "oslo"])
        #expect(candidates.allSatisfy { $0.gloss.isEmpty })
    }

    @Test("A translation long enough to wrap stays with its own word")
    func wrappedTranslation() {
        let candidates = WordListLayout.candidates(
            from: page([
                ["dyr", "expensive, dear, pricey,", "pricy, costly"],
                ["stor"],
            ])
        )

        #expect(candidates.count == 2)
        #expect(candidates[0].lemma == "dyr")
        #expect(candidates[0].gloss == "expensive, dear, pricey, pricy, costly")
        #expect(candidates[1].lemma == "stor")
    }

    @Test("A translation whose word was cut off above arrives unticked")
    func strandedGloss() throws {
        // A screenshot taken mid-scroll opens on half a row. Its translation is
        // readable and its word is not, which would import the English as if it
        // were the Norwegian.
        var lines = page([["fra", "from, of, since"], ["kommer"], ["oslo"]])
        lines.insert(
            line("also, too, as well", top: 0.04, height: glossHeight), at: 0
        )

        let candidates = WordListLayout.candidates(from: lines)
        let stranded = try #require(candidates.first { $0.lemma == "also, too, as well" })
        #expect(!stranded.isSelected)
        #expect(stranded.caution == WordListLayout.strandedCaution)
        // The rows below it are unaffected.
        #expect(candidates.first { $0.lemma == "fra" }?.gloss == "from, of, since")
        #expect(candidates.first { $0.lemma == "kommer" }?.isSelected == true)
    }

    @Test("App furniture arrives unticked rather than deleted")
    func chromeIsMarkedNotDropped() {
        // Marked, not dropped: a parser that silently discards what it dislikes
        // is indistinguishable from one that never saw the word.
        var lines = page([["liten", "small, little"], ["bor"], ["dyr", "expensive"]])
        lines.append(line("Practice your", top: 0.02, left: 0.04, width: 0.5, height: 0.03))
        lines.append(line("Norwegian words", top: 0.06, left: 0.04, width: 0.6, height: 0.03))
        lines.append(line("START +10 XP", top: 0.14, left: 0.38, width: 0.25))
        lines.append(line("SORT", top: 0.22, left: 0.86, width: 0.1))

        let candidates = WordListLayout.candidates(from: lines)
        let ticked = candidates.filter(\.isSelected).map(\.lemma)
        #expect(ticked == ["liten", "bor", "dyr"])

        let rejected = candidates.filter { !$0.isSelected }.map(\.lemma)
        #expect(Set(rejected) == ["Practice your", "Norwegian words", "START +10 XP", "SORT"])
        #expect(candidates.allSatisfy { $0.isSelected || $0.caution != nil })
    }

    @Test("The clock, the battery and the word count are not vocabulary")
    func numbersAndCounts() {
        #expect(!WordListLayout.isPlausibleWord("11:52"))
        #expect(!WordListLayout.isPlausibleWord("69"))
        #expect(!WordListLayout.isPlausibleWord("132 words"))
        #expect(!WordListLayout.isPlausibleWord("1,132 words"))
        #expect(!WordListLayout.isPlausibleWord("Practice Hub"))
    }

    @Test("Ordinary English words are no longer treated as furniture")
    func englishVocabularySurvives() {
        // The old blocklist held "all", "back", "done", "start", "continue" and
        // "review", which quietly deleted them from anyone learning English.
        for word in ["all", "back", "done", "start", "continue", "review", "search", "shop"] {
            #expect(WordListLayout.isPlausibleWord(word), "\(word) is a real word")
        }
    }
}

@Suite("Merging overlapping screenshots")
struct ScreenshotDedupeTests {
    @Test("The same word twice keeps the reading that has a translation")
    @MainActor
    func prefersTheCompleteReading() {
        let merged = ScreenshotImporter.dedupe([
            ImportCandidate(lemma: "fra", gloss: "", confidence: 0.9),
            ImportCandidate(lemma: "Fra", gloss: "from, of, since", confidence: 0.9),
        ])

        #expect(merged.count == 1)
        #expect(merged[0].gloss == "from, of, since")
    }

    @Test("A clean copy beats one flagged as cut off")
    @MainActor
    func prefersTheTickedReading() {
        let merged = ScreenshotImporter.dedupe([
            ImportCandidate(
                lemma: "også", gloss: "also, too", confidence: 0.9, isSelected: false,
                caution: WordListLayout.strandedCaution
            ),
            ImportCandidate(lemma: "også", gloss: "also, too, as well", confidence: 0.9),
        ])

        #expect(merged.count == 1)
        #expect(merged[0].isSelected)
        #expect(merged[0].gloss == "also, too, as well")
    }
}

/// The tests that prove the thing actually works. Everything above reasons about
/// geometry the parser was told; these run Vision over real screenshots of a
/// real Duolingo word list, so a redesign of that screen fails here loudly
/// instead of silently importing nonsense.
@Suite("Real Duolingo screenshots")
@MainActor
struct ScreenshotFixtureTests {
    /// What a human reads off each screenshot. An em dash means Duolingo showed
    /// no translation for that word.
    static let expected: [String: [(lemma: String, gloss: String?)]] = [
        "words-01": [
            ("liten", "small, little"),
            ("bor", nil),
            ("dyr", "expensive, dear, pricey, pricy, costly"),
            ("også", "also, too, as well"),
            ("stor", nil),
        ],
        "words-02": [
            ("stor", nil),
            ("by", nil),
            ("stort", nil),
            ("fra", "from, of, since"),
            ("kommer", nil),
            ("oslo", nil),
            ("Norge", "Norway"),
        ],
        "words-03": [
            ("dyr", "expensive, dear, pricey, pricy, costly"),
            ("også", "also, too, as well"),
            ("stor", nil),
            ("by", nil),
            ("stort", nil),
            ("fra", "from, of, since"),
            ("kommer", nil),
        ],
    ]

    static func fixture(_ name: String) throws -> UIImage {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "jpeg"),
            "\(name).jpeg is missing from the test bundle"
        )
        return try #require(UIImage(data: Data(contentsOf: url)))
    }

    static func read(_ name: String) async throws -> [ImportCandidate] {
        try await ScreenshotImporter.candidates(
            from: [fixture(name)], sourceLang: "en-US", targetLang: "nb-NO"
        )
    }

    @Test("Every word is found, and paired with its own translation", arguments: [
        "words-01", "words-02", "words-03",
    ])
    func pairsMatchTheScreen(name: String) async throws {
        let candidates = try await Self.read(name)
        let ticked = candidates.filter(\.isSelected)

        for word in try #require(Self.expected[name]) {
            let found = ticked.first { $0.lemma.importKey == word.lemma.importKey }
            let candidate = try #require(found, "\(word.lemma) was not read from \(name)")
            if let gloss = word.gloss {
                #expect(candidate.gloss == gloss, "\(word.lemma) in \(name)")
            } else {
                // Duolingo printed no translation, so the parser must not have
                // borrowed one from a neighbouring row.
                #expect(candidate.gloss.isEmpty, "\(word.lemma) in \(name) borrowed a translation")
            }
        }
    }

    @Test("The header, the button and the sort control don't reach the deck", arguments: [
        "words-01", "words-02", "words-03",
    ])
    func chromeIsNotTicked(name: String) async throws {
        let ticked = try await Self.read(name).filter(\.isSelected).map(\.lemma)
        for furniture in ["Words", "Practice your", "Norwegian words", "START +10 XP", "SORT"] {
            #expect(!ticked.contains(furniture), "\(furniture) was ticked in \(name)")
        }
        #expect(!ticked.contains { $0.contains("words") && $0.contains(where: \.isNumber) })
    }

    @Test("The row sheared off at the top of a mid-scroll shot arrives unticked")
    func clippedTopRow() async throws {
        // words-02 opens on "også" with the word cut off above the fold, so all
        // Vision can read of that row is its English translation. Left ticked,
        // "also, too, as well" would enter the deck as if it were Norwegian.
        let candidates = try await Self.read("words-02")
        let stranded = try #require(candidates.first { $0.lemma == "also, too, as well" })
        #expect(!stranded.isSelected)
        #expect(stranded.caution == WordListLayout.strandedCaution)
    }

    @Test("Overlapping screenshots collapse to one copy of each word")
    func overlapsMerge() async throws {
        let merged = try await ScreenshotImporter.candidates(
            from: [Self.fixture("words-02"), Self.fixture("words-03")],
            sourceLang: "en-US",
            targetLang: "nb-NO"
        )
        let keys = merged.map(\.lemma.importKey)
        #expect(Set(keys).count == keys.count, "the same word came through twice")

        // "fra" is glossed in both, "stor" in neither, and both appear in both
        // screenshots -- the merge must not lose or duplicate either.
        #expect(merged.filter { $0.lemma.importKey == "fra".importKey }.count == 1)
        #expect(merged.first { $0.lemma.importKey == "stor".importKey }?.isSelected == true)
    }
}

/// Locates the test bundle for `Bundle(for:)`, which needs a class.
private final class BundleToken {}
