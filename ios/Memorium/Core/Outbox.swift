import Foundation
import SwiftData

/// A grade recorded on the device, waiting to reach the server.
///
/// The server owns the deck, so a review is not real until it lands there. But
/// a study session on a train must not stop when the connection does: grades
/// are written here first and flushed when the network returns. `clientGradeId`
/// makes the flush idempotent, so a retry after a half-sent request cannot
/// double-schedule a card.
@Model
final class PendingGrade {
    #Unique<PendingGrade>([\.clientGradeId])

    var clientGradeId: String = UUID().uuidString
    var cardId: String = ""
    var rating: Int = 3
    var reviewedAt: Date = Date()
    var mode: String?
    var attempts: Int = 0

    init(cardId: String, rating: Rating, reviewedAt: Date = .now, mode: String? = nil) {
        self.clientGradeId = UUID().uuidString
        self.cardId = cardId
        self.rating = rating.rawValue
        self.reviewedAt = reviewedAt
        self.mode = mode
        self.attempts = 0
    }

    var payload: GradeIn {
        GradeIn(
            clientGradeId: clientGradeId,
            cardId: cardId,
            rating: rating,
            reviewedAt: reviewedAt,
            mode: mode
        )
    }
}

/// The study queue as last fetched, so a session survives losing signal
/// mid-review and so the app opens instantly rather than on a spinner.
@Model
final class CachedQueue {
    var fetchedAt: Date = Date()
    var payload: Data = Data()

    init(fetchedAt: Date = .now, payload: Data) {
        self.fetchedAt = fetchedAt
        self.payload = payload
    }
}

@MainActor
struct Outbox {
    let context: ModelContext

    func enqueue(cardId: String, rating: Rating, mode: String?) {
        context.insert(PendingGrade(cardId: cardId, rating: rating, mode: mode))
        try? context.save()
    }

    func pending() -> [PendingGrade] {
        let descriptor = FetchDescriptor<PendingGrade>(
            sortBy: [SortDescriptor(\.reviewedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    var count: Int { pending().count }

    /// Push everything queued. Returns the number of grades the server accepted.
    ///
    /// Entries are only deleted once the server has confirmed them, so a
    /// failure mid-flush leaves the work queued rather than losing it.
    @discardableResult
    func flush(using client: APIClient) async -> Int {
        let queued = pending()
        guard !queued.isEmpty else { return 0 }

        let batch = queued.map(\.payload)
        let results: [GradeResult]
        do {
            results = try await client.submit(grades: batch)
        } catch let error as APIError where error.isTransient {
            for grade in queued { grade.attempts += 1 }
            try? context.save()
            return 0
        } catch {
            for grade in queued { grade.attempts += 1 }
            try? context.save()
            return 0
        }

        let settled = Set(results.filter(\.accepted).map(\.clientGradeId))
        var cleared = 0
        for grade in queued where settled.contains(grade.clientGradeId) {
            context.delete(grade)
            cleared += 1
        }

        // A grade the server rejected outright (deleted card, say) would
        // otherwise retry forever and block every later flush.
        let rejected = Set(results.filter { !$0.accepted }.map(\.clientGradeId))
        for grade in queued where rejected.contains(grade.clientGradeId) {
            context.delete(grade)
        }

        try? context.save()
        return cleared
    }

    func cacheQueue(_ queue: StudyQueue) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        let existing = (try? context.fetch(FetchDescriptor<CachedQueue>())) ?? []
        for item in existing { context.delete(item) }
        context.insert(CachedQueue(payload: data))
        try? context.save()
    }

    func cachedQueue() -> StudyQueue? {
        let items = (try? context.fetch(FetchDescriptor<CachedQueue>())) ?? []
        guard let latest = items.max(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
        return try? JSONDecoder().decode(StudyQueue.self, from: latest.payload)
    }
}
