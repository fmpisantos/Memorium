import Foundation
import Testing

@testable import Memorium

/// Tier 1 of the grader runs on every typed answer before any model is
/// consulted, so its notion of "same answer" decides most gradings.
@Suite("Answer normalising")
struct NormalisingTests {
    @Test("Case and surrounding whitespace are ignored")
    func caseAndWhitespace() {
        #expect(LocalGrader.normalise("  El Perro ") == LocalGrader.normalise("el perro"))
    }

    @Test("A missing accent is a typing slip, not a vocabulary failure")
    func accents() {
        #expect(LocalGrader.normalise("está") == LocalGrader.normalise("esta"))
    }

    @Test("Nordic letters fold too, even though Unicode won't decompose them")
    func nonDecomposingLetters() {
        // ø, å, æ and friends have no base-plus-diacritic form, so Apple's
        // .diacriticInsensitive folding leaves them alone. Someone without the
        // Norwegian keyboard installed cannot type them at all.
        #expect(LocalGrader.normalise("løpe") == LocalGrader.normalise("lope"))
        #expect(LocalGrader.normalise("på") == LocalGrader.normalise("pa"))
        #expect(LocalGrader.normalise("æble") == LocalGrader.normalise("aeble"))
        #expect(LocalGrader.normalise("straße") == LocalGrader.normalise("strasse"))
    }

    @Test("Punctuation is stripped")
    func punctuation() {
        #expect(LocalGrader.normalise("¿el perro?") == LocalGrader.normalise("el perro"))
    }

    @Test("A leading article is optional on a multi-word answer")
    func leadingArticles() {
        #expect(LocalGrader.normalise("el perro") == LocalGrader.normalise("perro"))
        #expect(LocalGrader.normalise("the dog") == LocalGrader.normalise("dog"))
        #expect(LocalGrader.normalise("der Hund") == LocalGrader.normalise("hund"))
    }

    @Test("A word that IS an article survives normalising")
    func articleAsAnswer() {
        // Otherwise answering the card for "el" normalises to nothing and can
        // never be marked correct.
        #expect(!LocalGrader.normalise("el").isEmpty)
        #expect(LocalGrader.normalise("el") == "el")
    }

    @Test("Genuinely different words stay different")
    func distinctWords() {
        #expect(LocalGrader.normalise("perro") != LocalGrader.normalise("pero"))
        #expect(LocalGrader.normalise("hund") != LocalGrader.normalise("hunder"))
    }
}

@Suite("Card presentation rules")
struct CardRuleTests {
    private func card(_ kind: CardKind, autoplay: Bool) -> StudyCard {
        StudyCard(
            cardId: "c", wordId: "w", kind: kind,
            lemma: "perro", nativeGloss: "dog", article: "el", pos: "noun",
            prompt: "p", answer: "a", speechText: "perro", audioAutoplay: autoplay,
            sentenceTarget: nil, sentenceNative: nil, clozeAnswer: nil,
            isNew: true, isLeech: false, due: .now
        )
    }

    @Test("Only cloze cards are answered by typing")
    func typedKinds() {
        #expect(CardKind.cloze.isTyped)
        #expect(!CardKind.recognition.isTyped)
        #expect(!CardKind.production.isTyped)
        #expect(!CardKind.listening.isTyped)
    }

    @Test("Every card can be spoken on demand, even the silent ones")
    func speechAlwaysAvailable() {
        // The Repeat button works on a production card too -- the rule is
        // about *auto*-play, not about withholding the audio entirely.
        let production = card(.production, autoplay: false)
        #expect(!production.audioAutoplay)
        #expect(!production.speechText.isEmpty)
    }
}

@Suite("Grade payloads")
struct GradePayloadTests {
    @Test("Every queued grade carries a unique id so replays are idempotent")
    func uniqueIds() {
        let a = PendingGrade(cardId: "c1", rating: .good)
        let b = PendingGrade(cardId: "c1", rating: .good)
        #expect(a.clientGradeId != b.clientGradeId)
    }

    @Test("Rating survives the round trip to the payload")
    func ratingRoundTrip() {
        for rating in Rating.allCases {
            #expect(PendingGrade(cardId: "c", rating: rating).payload.rating == rating.rawValue)
        }
    }
}

@Suite("Date decoding")
struct DateDecodingTests {
    @Test("Microsecond timestamps from the server parse")
    func fractionalSeconds() {
        // The stock .iso8601 strategy rejects these outright, which would make
        // every single response fail to decode.
        #expect(DateCoding.parse("2026-08-03T18:07:33.407123+00:00") != nil)
    }

    @Test("Whole-second timestamps still parse")
    func plainSeconds() {
        #expect(DateCoding.parse("2026-08-03T18:07:33+00:00") != nil)
    }

    @Test("Nonsense is rejected rather than silently becoming a date")
    func garbage() {
        #expect(DateCoding.parse("not a date") == nil)
    }
}
