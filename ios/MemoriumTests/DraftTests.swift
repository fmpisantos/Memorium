import Foundation
import Testing

@testable import Memorium

/// A draft is what stands between typing a word and it reaching the deck.
/// Its completeness rule is what Done consults, so a half-translated word
/// getting past it would put a one-sided card in the deck.
@Suite("Staged words")
struct WordDraftTests {
    @Test("A word typed on both sides is ready to send")
    func bothSidesTyped() {
        let draft = WordDraft(lemma: "perro", gloss: "dog", notes: "")
        #expect(draft.isComplete)
        #expect(draft.failure == nil)
    }

    @Test("A word still being translated is not ready")
    func stillTranslating() {
        let draft = WordDraft(lemma: "perro", gloss: "", notes: "", status: .translating)
        #expect(!draft.isComplete)
    }

    @Test("A failed translation blocks the word and keeps its reason")
    func failedTranslation() {
        let draft = WordDraft(
            lemma: "perro", gloss: "", notes: "", status: .failed("Can't reach the server.")
        )
        #expect(!draft.isComplete)
        #expect(draft.failure == "Can't reach the server.")
    }

    @Test("A blank side is incomplete even once translating has stopped")
    func readyButEmpty() {
        // The translation returned nothing and left the status alone: the
        // status flag alone must not be enough to let it through.
        #expect(!WordDraft(lemma: "perro", gloss: "", notes: "").isComplete)
        #expect(!WordDraft(lemma: "", gloss: "dog", notes: "").isComplete)
    }

    @Test("Correcting a draft by hand clears the failure")
    func correctionClearsFailure() {
        var draft = WordDraft(lemma: "perro", gloss: "", notes: "", status: .failed("offline"))
        draft.gloss = "dog"
        draft.status = .ready
        #expect(draft.isComplete)
        #expect(draft.failure == nil)
    }

    @Test("Drafts stay distinct even when the same word is typed twice")
    func identityIsPerDraft() {
        // Rows are addressed by id when swiping to edit or delete; two
        // identical words must not both vanish on one swipe.
        let first = WordDraft(lemma: "perro", gloss: "dog", notes: "")
        let second = WordDraft(lemma: "perro", gloss: "dog", notes: "")
        #expect(first.id != second.id)
    }
}
