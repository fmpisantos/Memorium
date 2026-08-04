import Foundation
import SwiftData

/// The last set of phrases fetched, kept so practice survives losing signal.
///
/// The server writes these; the phone only borrows them. Keeping the last
/// batch on disk is what makes this the one screen that still works on a
/// train -- there is no local generator to fall back on, and a sentence
/// practised twice is a great deal better than an empty screen.
@Model
final class CachedPhrases {
    var fetchedAt: Date = Date()
    var payload: Data = Data()

    init(fetchedAt: Date = .now, payload: Data) {
        self.fetchedAt = fetchedAt
        self.payload = payload
    }
}

/// How a phrase went, waiting to reach the server.
///
/// The rotation lives on the server: a sentence keeps being served until it
/// has been answered correctly, and this is what tells it that happened. An
/// answer given on a train has to survive the journey, or the same sentences
/// come back for ever and the ones behind them never arrive.
@Model
final class PendingPhraseResult {
    #Unique<PendingPhraseResult>([\.clientResultId])

    var clientResultId: String = UUID().uuidString
    var phraseId: String = ""
    var correct: Bool = false
    var answeredAt: Date = Date()
    var attempts: Int = 0

    init(phraseId: String, correct: Bool, answeredAt: Date = .now) {
        self.clientResultId = UUID().uuidString
        self.phraseId = phraseId
        self.correct = correct
        self.answeredAt = answeredAt
        self.attempts = 0
    }

    var payload: PhraseResultIn {
        PhraseResultIn(
            clientResultId: clientResultId,
            phraseId: phraseId,
            correct: correct,
            answeredAt: answeredAt
        )
    }
}

@MainActor
struct PhraseStore {
    let context: ModelContext

    // MARK: - The borrowed set

    func cache(_ set: PhraseSet) {
        guard let data = try? JSONEncoder().encode(set) else { return }
        let existing = (try? context.fetch(FetchDescriptor<CachedPhrases>())) ?? []
        for item in existing { context.delete(item) }
        context.insert(CachedPhrases(payload: data))
        try? context.save()
    }

    /// The last batch, or nil if there has never been one.
    func cached() -> PhraseSet? {
        let items = (try? context.fetch(FetchDescriptor<CachedPhrases>())) ?? []
        guard let latest = items.max(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
        return try? JSONDecoder().decode(PhraseSet.self, from: latest.payload)
    }

    /// Drop a sentence that has been answered correctly.
    ///
    /// The server has already retired it, but a phone that loses signal falls
    /// back to this copy -- and being asked again offline for the one sentence
    /// you got right is exactly the repetition this feature exists to avoid.
    /// A sentence answered *wrong* is deliberately left where it is.
    func retire(phraseId: String) {
        guard let set = cached() else { return }
        let remaining = set.phrases.filter { $0.id != phraseId }
        guard remaining.count != set.phrases.count else { return }
        cache(
            PhraseSet(
                targetLang: set.targetLang,
                sourceLang: set.sourceLang,
                phrases: remaining,
                poolDepth: max(set.poolDepth - 1, 0)
            )
        )
    }

    // MARK: - Results waiting to be sent

    func record(phraseId: String, correct: Bool) {
        context.insert(PendingPhraseResult(phraseId: phraseId, correct: correct))
        try? context.save()
        if correct { retire(phraseId: phraseId) }
    }

    func pendingResults() -> [PendingPhraseResult] {
        let descriptor = FetchDescriptor<PendingPhraseResult>(
            sortBy: [SortDescriptor(\.answeredAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Push everything queued. Returns how many the server took.
    ///
    /// Entries are deleted once the server has answered for them -- accepted
    /// or refused. A refusal means the sentence is gone from the server
    /// altogether, and retrying it would block every result behind it.
    @discardableResult
    func flushResults(using client: APIClient) async -> Int {
        let queued = pendingResults()
        guard !queued.isEmpty else { return 0 }

        let results: [PhraseResultOut]
        do {
            results = try await client.submit(phraseResults: queued.map(\.payload))
        } catch {
            for result in queued { result.attempts += 1 }
            try? context.save()
            return 0
        }

        let settled = Set(results.map(\.clientResultId))
        var accepted = 0
        for result in queued where settled.contains(result.clientResultId) {
            context.delete(result)
            accepted += 1
        }
        try? context.save()
        return accepted
    }
}
