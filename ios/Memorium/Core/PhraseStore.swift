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

@MainActor
struct PhraseStore {
    let context: ModelContext

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
}
