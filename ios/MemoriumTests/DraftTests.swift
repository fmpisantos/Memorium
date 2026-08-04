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

/// The deck holds each word once, so the list that feeds it does too. Staging
/// a word twice has to show one row, or Done sends two and one of them
/// disappears into the server's own deduplication with nothing said.
@Suite("The list of staged words is a set")
struct DraftStagingTests {
    private func draft(_ lemma: String, _ gloss: String) -> WordDraft {
        WordDraft(lemma: lemma, gloss: gloss, notes: "")
    }

    @Test("Different words all stay, newest first")
    func distinctWordsAccumulate() {
        var drafts: [WordDraft] = []
        #expect(drafts.stage(draft("perro", "dog")) == nil)
        #expect(drafts.stage(draft("gato", "cat")) == nil)
        #expect(drafts.map(\.lemma) == ["gato", "perro"])
    }

    @Test("Staging a word already in the list replaces it instead of repeating it")
    func repeatReplaces() {
        var drafts = [draft("gato", "cat"), draft("perro", "dog")]
        let displaced = drafts.stage(draft("perro", "hound"))

        #expect(displaced?.gloss == "dog")
        #expect(drafts.count == 2)
        // The newest take wins, and rises to the top where it can be seen.
        #expect(drafts.map(\.lemma) == ["perro", "gato"])
        #expect(drafts[0].gloss == "hound")
    }

    @Test("Case is not a second word")
    func caseIsIgnored() {
        // The translator capitalises a word it produces on its own, so this
        // is how a repeat usually arrives rather than a typing mistake.
        var drafts = [draft("perro", "dog")]
        #expect(drafts.stage(draft("Perro", "dog")) != nil)
        #expect(drafts.map(\.lemma) == ["Perro"])
    }

    @Test("Spacing is not a second word either")
    func spacingIsIgnored() {
        var drafts = [draft("el gato", "the cat")]
        #expect(drafts.stage(draft("el  gato", "the cat")) != nil)
        #expect(drafts.count == 1)
    }

    @Test("Words still waiting for their translation are not all the same word")
    func untranslatedDraftsAreNotCopies() {
        // Both are typed gloss-first and have no word yet. Matching them on an
        // empty lemma would throw one of them away before it ever had a name.
        var drafts: [WordDraft] = []
        drafts.stage(WordDraft(lemma: "", gloss: "dog", notes: "", status: .translating))
        drafts.stage(WordDraft(lemma: "", gloss: "cat", notes: "", status: .translating))
        #expect(drafts.count == 2)
    }
}

/// A word in the deck keeps its id when it is edited, so equality is the only
/// thing telling SwiftUI the row on screen is out of date.
@Suite("Deck rows notice an edit")
struct WordEqualityTests {
    private func word(
        lemma: String = "perro",
        gloss: String = "dog",
        notes: String? = nil,
        article: String? = nil,
        status: EnrichmentStatus = .done
    ) -> Word {
        Word(
            id: "w1",
            lemma: lemma,
            nativeGloss: gloss,
            pos: nil,
            gender: nil,
            article: article,
            pluralForm: nil,
            notes: notes,
            enrichmentStatus: status,
            createdAt: Date(timeIntervalSince1970: 0),
            cards: []
        )
    }

    @Test("An unchanged word compares equal, so untouched rows are left alone")
    func unchangedIsEqual() {
        #expect(word() == word())
    }

    @Test("Every field the row shows makes the word unequal once it changes")
    func editedIsUnequal() {
        // Each of these is drawn by WordRow. Comparing ids alone would report
        // "no change" and leave the old text on screen after a save.
        #expect(word() != word(lemma: "gato"))
        #expect(word() != word(gloss: "cat"))
        #expect(word() != word(notes: "irregular"))
        #expect(word() != word(article: "el"))
        #expect(word() != word(status: .pending))
    }
}
