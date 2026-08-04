import Foundation
import Testing

@testable import Memorium

private let phrase = Phrase(
    id: "p1",
    target: "Jeg trenger vann.",
    native: "I need water.",
    lemmas: ["trenge", "vann"]
)

/// Which side of a phrase is the question, and what the answer is graded
/// against, is the whole of this feature. Getting it backwards would mark a
/// correct answer wrong in a way nothing else would catch.
@Suite("Practice directions")
struct PracticeModeTests {
    @Test("A dictation shows nothing and expects the sentence back")
    func dictation() {
        #expect(PracticeMode.dictation.prompt(for: phrase).isEmpty)
        #expect(PracticeMode.dictation.expected(for: phrase) == phrase.target)
        #expect(PracticeMode.dictation.promptIsAudio)
        #expect(PracticeMode.dictation.answerIsTarget)
    }

    @Test("Listening for meaning shows nothing and expects your own language")
    func listenAndTranslate() {
        #expect(PracticeMode.listenAndTranslate.prompt(for: phrase).isEmpty)
        #expect(PracticeMode.listenAndTranslate.expected(for: phrase) == phrase.native)
        #expect(!PracticeMode.listenAndTranslate.answerIsTarget)
    }

    @Test("Reading swaps the sides")
    func reading() {
        #expect(PracticeMode.intoTarget.prompt(for: phrase) == phrase.native)
        #expect(PracticeMode.intoTarget.expected(for: phrase) == phrase.target)
        #expect(PracticeMode.intoNative.prompt(for: phrase) == phrase.target)
        #expect(PracticeMode.intoNative.expected(for: phrase) == phrase.native)
    }

    @Test("The prompt and the expected answer are never the same text")
    func neverGivesItself() {
        for mode in PracticeMode.allCases {
            #expect(mode.prompt(for: phrase) != mode.expected(for: phrase))
        }
    }

    @Test("Audio never plays up front when the audio is the answer")
    func autoplay() {
        // Reading your own language and producing the target is the one
        // direction where hearing the sentence would hand it over.
        #expect(!PracticeMode.intoTarget.playsPromptAudio)
        #expect(PracticeMode.dictation.playsPromptAudio)
        #expect(PracticeMode.listenAndTranslate.playsPromptAudio)
        #expect(PracticeMode.intoNative.playsPromptAudio)
    }

    @Test("Only a dictation is marked as a dictation")
    func rubric() {
        #expect(PracticeMode.dictation.gradeKind == .dictation)
        #expect(PracticeMode.listenAndTranslate.gradeKind == .sentence)
        #expect(PracticeMode.intoTarget.gradeKind == .sentence)
        #expect(PracticeMode.intoNative.gradeKind == .sentence)
    }

    @Test("A word-by-word diff is offered only where there is one right answer")
    func diffOnlyForDictation() {
        // Marking a translation word by word against one reference would flag
        // perfectly good wording as a mistake.
        for mode in PracticeMode.allCases {
            #expect(mode.showsWordDiff == (mode == .dictation))
        }
    }
}

@Suite("Sentence normalising")
struct SentenceNormalisingTests {
    @Test("Punctuation and case don't decide a dictation")
    func punctuation() {
        #expect(
            LocalGrader.normalise("Jeg trenger vann!", droppingArticles: false)
                == LocalGrader.normalise("jeg trenger vann", droppingArticles: false)
        )
    }

    @Test("A dropped article is a mistake in a dictation, not a slip")
    func articlesMatterWhenTranscribing() {
        // Everywhere else "el perro" and "perro" are the same answer. Here the
        // article is exactly what the listening test is testing.
        #expect(
            LocalGrader.normalise("el perro corre", droppingArticles: false)
                != LocalGrader.normalise("perro corre", droppingArticles: false)
        )
        #expect(LocalGrader.normalise("el perro corre") == LocalGrader.normalise("perro corre"))
    }
}

/// Being told "close" after writing down a sentence you half-heard is not
/// feedback. Which word went missing is the entire question.
@Suite("Dictation diff")
struct AnswerDiffTests {
    @Test("A perfect transcription has nothing to report")
    func perfect() {
        let diff = AnswerDiff.compare(expected: "Jeg trenger vann", given: "jeg trenger vann!")
        #expect(diff.isPerfect)
        #expect(diff.extras.isEmpty)
    }

    @Test("The missed word is the one marked")
    func missingWord() {
        let diff = AnswerDiff.compare(expected: "Jeg trenger mye vann", given: "Jeg trenger vann")
        #expect(diff.expected.filter(\.isMissed).map(\.text) == ["mye"])
        #expect(!diff.isPerfect)
    }

    @Test("A mishearing shows both halves of the swap")
    func swappedWord() {
        let diff = AnswerDiff.compare(expected: "Jeg trenger vann", given: "Jeg trener vann")
        #expect(diff.expected.filter(\.isMissed).map(\.text) == ["trenger"])
        #expect(diff.extras == ["trener"])
    }

    @Test("An extra word early on doesn't mark the rest of the sentence wrong")
    func alignmentSurvivesAnInsertion() {
        // The most common dictation mistake there is. A positional comparison
        // would report every word after the insertion as missed.
        let diff = AnswerDiff.compare(
            expected: "Jeg trenger vann", given: "Jeg så trenger vann"
        )
        #expect(diff.expected.filter(\.isMissed).isEmpty)
        #expect(diff.extras == ["så"])
    }

    @Test("The sentence comes back spelled the way it is really written")
    func keepsOriginalSpelling() {
        // Matching folds accents someone's keyboard can't produce; what is
        // shown must not.
        let diff = AnswerDiff.compare(expected: "Jeg må gå", given: "jeg ma ga")
        #expect(diff.expected.map(\.text) == ["Jeg", "må", "gå"])
        #expect(diff.isPerfect)
    }

    @Test("Nothing written means nothing caught")
    func emptyAnswer() {
        let diff = AnswerDiff.compare(expected: "Jeg trenger vann", given: "")
        #expect(diff.expected.filter(\.isMissed).count == diff.expected.count)
    }
}
