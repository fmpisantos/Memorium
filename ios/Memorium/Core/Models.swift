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
    /// Served ahead of its due date because extra practice was asked for.
    /// Answering it is recorded but deliberately does not move the schedule.
    let isPractice: Bool
    let due: Date

    var id: String { cardId }
}

struct StudyQueue: Codable, Sendable {
    let targetLang: String
    let sourceLang: String
    let cards: [StudyCard]
    let dueCount: Int
    let newCount: Int
    let practiceCount: Int
    let newRemainingToday: Int
    /// True when this is an extra round rather than the day's own work.
    let extra: Bool
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
    let practice: Bool
    let nextDue: Date?
    let intervalDays: Double?
    let isLeech: Bool
    let unlockedKinds: [CardKind]
}

struct GradeBatchResult: Codable, Sendable {
    let results: [GradeResult]
}

struct CardSummary: Codable, Sendable, Identifiable, Equatable {
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

    // Equality is synthesised on purpose. Comparing ids alone reads as
    // "same word", but SwiftUI uses this to decide whether a row needs
    // redrawing: an edited word kept its id, so the deck went on showing
    // the old spelling until something else forced the list to rebuild.

    var display: String { article.map { "\($0) \(lemma)" } ?? lemma }
}

struct WordCreate: Codable, Sendable {
    let lemma: String
    let nativeGloss: String
    var notes: String?
    /// Where the word came from -- "manual" or "ocr". The server has recorded
    /// this since the schema was written; the app just never sent it, so every
    /// screenshot import looked hand-typed. Omitted rather than defaulted here,
    /// so the server's own default still applies to callers that don't care.
    var source: WordSource?
}

enum WordSource: String, Codable, Sendable {
    case manual
    case ocr
}

/// Every field is sent on every edit: the form always holds all three, and
/// clearing the notes has to reach the server as an empty string rather than
/// as an omitted key the server would read as "leave it alone".
struct WordUpdate: Codable, Sendable {
    let lemma: String
    let nativeGloss: String
    let notes: String
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

/// What was being asked, which decides how the answer is marked.
///
/// A word and a translated sentence are marked on meaning; a dictation is
/// marked on the words themselves, because it is a listening test and a
/// flawless paraphrase means the learner did not actually hear it.
enum GradeKind: String, Codable, Sendable {
    case word, sentence, dictation
}

struct GradeAnswerRequest: Codable, Sendable {
    let prompt: String
    let expected: String
    let given: String
    var kind: GradeKind = .word
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

struct TranslateBatchRequest: Codable, Sendable {
    let texts: [String]
    let into: TranslationDirection
}

struct TranslateBatchResponse: Codable, Sendable {
    /// One entry per word sent, in the same order. A word the server couldn't
    /// translate comes back as nil rather than being dropped, so the blanks stay
    /// attached to the word they belong to.
    let translations: [String?]
    let into: TranslationDirection
}

/// A whole sentence, built from words already in the deck.
///
/// Both sides arrive together because which one is the question is this app's
/// decision: hearing it and writing it down, or reading it in one language and
/// producing it in the other, are the same phrase asked four ways.
struct Phrase: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let target: String
    let native: String
    /// The deck words it was built from, shown once the answer is out.
    let lemmas: [String]
    /// How it has gone before. A sentence only comes back because it was
    /// missed, so the card says so rather than letting it look new.
    var attempts: Int = 0
    var lapses: Int = 0

    var isReturning: Bool { lapses > 0 }
}

struct PhraseSet: Codable, Sendable, Equatable {
    let targetLang: String
    let sourceLang: String
    let phrases: [Phrase]
    /// Sentences the server has in store, waiting to be answered. Nothing is
    /// drawn with it; it is what tells the app the pool is filling.
    var poolDepth: Int = 0
}

/// How one phrase went, on its way back to the server.
///
/// `clientResultId` makes the flush idempotent, for the same reason a grade
/// carries one: a result is written to the device first and sent when the
/// network allows, so the same one can legitimately arrive twice.
struct PhraseResultIn: Codable, Sendable {
    let clientResultId: String
    let phraseId: String
    let correct: Bool
    let answeredAt: Date
}

struct PhraseResultOut: Codable, Sendable {
    let clientResultId: String
    let phraseId: String
    let accepted: Bool
    var duplicate: Bool = false
    /// Answered correctly: it has left the rotation for good.
    var mastered: Bool = false
    var retryAfter: Date?
}

struct PhraseResultBatchResult: Codable, Sendable {
    let results: [PhraseResultOut]
}

struct StoryResponse: Codable, Sendable {
    let title: String
    let target: String
    let native: String
    let lemmas: [String]
}
