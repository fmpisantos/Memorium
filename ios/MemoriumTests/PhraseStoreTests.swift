import Foundation
import SwiftData
import Testing

@testable import Memorium

/// The device's half of "keep asking until I get it right".
///
/// The rotation itself lives on the server, but the phone keeps a copy of the
/// last set so practice survives losing signal -- and that copy has to obey the
/// same rule, or an offline session hands back the one sentence you already
/// got right and calls it practice.
@MainActor
@Suite("Phrase store")
struct PhraseStoreTests {
    private func makeStore() throws -> PhraseStore {
        let container = try ModelContainer(
            for: CachedPhrases.self, PendingPhraseResult.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return PhraseStore(context: ModelContext(container))
    }

    private func phraseSet(_ ids: [String]) -> PhraseSet {
        PhraseSet(
            targetLang: "es-ES",
            sourceLang: "en-US",
            phrases: ids.map {
                Phrase(id: $0, target: "target \($0)", native: "native \($0)", lemmas: [])
            },
            poolDepth: ids.count
        )
    }

    @Test("A sentence answered right is done with")
    func rightAnswerRetiresIt() throws {
        let store = try makeStore()
        store.cache(phraseSet(["a", "b", "c"]))

        store.record(phraseId: "b", correct: true)

        #expect(store.cached()?.phrases.map(\.id) == ["a", "c"])
    }

    @Test("A sentence answered wrong is kept, and comes back")
    func wrongAnswerKeepsIt() throws {
        let store = try makeStore()
        store.cache(phraseSet(["a", "b", "c"]))

        store.record(phraseId: "b", correct: false)

        #expect(store.cached()?.phrases.map(\.id) == ["a", "b", "c"])
    }

    @Test("Both kinds of answer are queued for the server")
    func everyAnswerIsQueued() throws {
        // Including the wrong ones: how long a sentence sits out before it is
        // asked again is the server's decision, and it cannot make it from
        // answers it never heard about.
        let store = try makeStore()
        store.cache(phraseSet(["a", "b"]))

        store.record(phraseId: "a", correct: true)
        store.record(phraseId: "b", correct: false)

        let queued = store.pendingResults()
        #expect(Set(queued.map(\.phraseId)) == ["a", "b"])
        #expect(Set(queued.map(\.clientResultId)).count == 2, "each one is separately replayable")
    }

    @Test("An answer to a sentence from an older set is still reported")
    func answersOutliveTheirSet() throws {
        // The set is replaced every time the screen is opened, and results are
        // flushed on the next connection -- which can easily be later.
        let store = try makeStore()
        store.cache(phraseSet(["a"]))
        store.record(phraseId: "a", correct: true)

        store.cache(phraseSet(["x", "y"]))

        #expect(store.pendingResults().map(\.phraseId) == ["a"])
    }
}
