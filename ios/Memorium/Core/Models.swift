import Foundation

// Mirrors of the server DTOs. Field names match the JSON exactly, so the
// decoder is configured with `.convertFromSnakeCase` and nothing needs
// CodingKeys.

enum CardKind: String, Codable, Sendable, CaseIterable {
    case recognition, production, listening, cloze

    var title: String {
        switch self {
        case .recognition: "Recognise"
        case .production: "Produce"
        case .listening: "Listen"
        case .cloze: "Fill the blank"
        }
    }

    /// Cloze answers are typed; the rest are self-graded after reveal.
    var isTyped: Bool { self == .cloze }
}

enum Rating: Int, Codable, Sendable, CaseIterable {
    case again = 1, hard = 2, good = 3, easy = 4

    var label: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

enum EnrichmentStatus: String, Codable, Sendable {
    case pending, queued, running, done, failed
}

struct StudyCard: Codable, Sendable, Identifiable, Equatable {
    let cardId: String
    let wordId: String
    let kind: CardKind

    let lemma: String
    let nativeGloss: String
    let article: String?
    let pos: String?

    let prompt: String
    let answer: String
    let speechText: String
    /// False on production and cloze cards, where the target-language audio
    /// *is* the answer and playing it up front would give the game away.
    let audioAutoplay: Bool

    let sentenceTarget: String?
    let sentenceNative: String?
    let clozeAnswer: String?

    let isNew: Bool
    let isLeech: Bool
    let due: Date

    var id: String { cardId }
}

struct StudyQueue: Codable, Sendable {
    let targetLang: String
    let sourceLang: String
    let cards: [StudyCard]
    let dueCount: Int
    let newCount: Int
    let newRemainingToday: Int
}

struct GradeIn: Codable, Sendable {
    let clientGradeId: String
    let cardId: String
    let rating: Int
    let reviewedAt: Date
    let mode: String?
}

struct GradeResult: Codable, Sendable {
    let clientGradeId: String
    let cardId: String
    let accepted: Bool
    let duplicate: Bool
    let nextDue: Date?
    let intervalDays: Double?
    let isLeech: Bool
    let unlockedKinds: [CardKind]
}

struct GradeBatchResult: Codable, Sendable {
    let results: [GradeResult]
}

struct CardSummary: Codable, Sendable, Identifiable {
    let id: String
    let kind: CardKind
    let state: Int
    let stability: Double?
    let due: Date
    let reps: Int
    let lapses: Int
    let isLeech: Bool
}

struct Word: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let lemma: String
    let nativeGloss: String
    let pos: String?
    let gender: String?
    let article: String?
    let pluralForm: String?
    let notes: String?
    let enrichmentStatus: EnrichmentStatus
    let createdAt: Date
    let cards: [CardSummary]

    static func == (lhs: Word, rhs: Word) -> Bool { lhs.id == rhs.id }

    var display: String { article.map { "\($0) \(lemma)" } ?? lemma }
}

struct WordCreate: Codable, Sendable {
    let lemma: String
    let nativeGloss: String
    var notes: String?
}

struct WordBatchCreate: Codable, Sendable {
    let words: [WordCreate]
}

struct WordBatchResult: Codable, Sendable {
    let created: [Word]
    let duplicates: [String]
}

struct Profile: Codable, Sendable {
    var sourceLang: String
    var targetLang: String
    var desiredRetention: Double
    var dailyNewLimit: Int
    var timezone: String
}

struct ProfileUpdate: Codable, Sendable {
    var sourceLang: String?
    var targetLang: String?
    var desiredRetention: Double?
    var dailyNewLimit: Int?
    var timezone: String?
}

struct MeResponse: Codable, Sendable {
    let email: String
}

struct HealthStatus: Codable, Sendable {
    let status: String
    let db: String
    let claudeAuth: String
    let claudeDetail: String
    let queueDepth: Int
    let enrichmentFailed: Int

    /// Surfaced in the UI: an expired Agent SDK token is the most likely
    /// long-run failure, and it must not look like "sentences just stopped".
    var claudeIsHealthy: Bool { claudeAuth == "ok" }
}

struct EnrichStatus: Codable, Sendable {
    let queueDepth: Int
    let pending: Int
    let running: Int
    let done: Int
    let failed: Int
}

struct GradeAnswerRequest: Codable, Sendable {
    let prompt: String
    let expected: String
    let given: String
}

struct GradeAnswerResponse: Codable, Sendable {
    let verdict: String
    let reason: String
}

/// Which side of a card the server should fill in.
enum TranslationDirection: String, Codable, Sendable {
    /// Into the language being learned: the learner typed the gloss.
    case target
    /// Into the learner's own language: they typed the foreign word.
    case source
}

struct TranslateRequest: Codable, Sendable {
    let text: String
    let into: TranslationDirection
}

struct TranslateResponse: Codable, Sendable {
    let translation: String
    let into: TranslationDirection
}

struct StoryResponse: Codable, Sendable {
    let title: String
    let target: String
    let native: String
    let lemmas: [String]
}
