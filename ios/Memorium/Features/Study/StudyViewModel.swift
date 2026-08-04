import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class StudyViewModel {
    enum Phase: Equatable {
        case loading
        case question
        case revealed
        case finished
        case empty(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var cards: [StudyCard] = []
    private(set) var index = 0
    private(set) var reviewedCount = 0
    private(set) var pendingUpload = 0
    private(set) var isOffline = false

    /// True while this session is an extra round rather than the day's own
    /// queue. Nothing in it moves the schedule unless a card was genuinely due.
    private(set) var isExtra = false

    /// Cards skipped this session, re-appended once the main run is done.
    private var deferred: [StudyCard] = []

    /// How many other cards have to sit between two cards of the same word.
    /// Mirrors `SIBLING_GAP` on the server, which spaces the queue it serves.
    nonisolated static let siblingGap = 4

    // Typed-answer state (cloze cards).
    var typedAnswer = ""
    private(set) var judgement: Judgement?
    private(set) var isJudging = false

    // Speaking practice
    let recogniser = RecognitionService()
    private(set) var spokenScore: Double?

    private let settings: AppSettings
    private let speech: SpeechService
    private let outbox: Outbox

    init(settings: AppSettings, speech: SpeechService, context: ModelContext) {
        self.settings = settings
        self.speech = speech
        self.outbox = Outbox(context: context)
        self.pendingUpload = outbox.count
    }

    /// Speaking replaces the answer input, so it only applies to cards whose
    /// answer is in the target language -- there is nothing to pronounce on a
    /// card whose answer is your own language.
    var speakingApplies: Bool {
        guard settings.speakingMode, let card = current else { return false }
        return card.kind == .production || card.kind == .cloze
    }

    func startListening() async {
        spokenScore = nil
        recogniser.reset()
        await recogniser.start(locale: settings.targetLang)
    }

    func stopListening() {
        recogniser.stop()
        guard let card = current else { return }
        let expected = card.clozeAnswer ?? card.answer
        let score = RecognitionService.similarity(
            said: recogniser.transcript, expected: expected
        )
        spokenScore = score
        judgement = Judgement(
            verdict: score >= 0.85 ? .correct : (score >= 0.5 ? .close : .wrong),
            reason: recogniser.transcript.isEmpty
                ? "Didn't catch anything."
                : "Heard “\(recogniser.transcript)”.",
            source: .onDevice
        )
        reveal()
    }

    var current: StudyCard? {
        guard index < cards.count else { return nil }
        return cards[index]
    }

    var progress: Double {
        cards.isEmpty ? 0 : Double(index) / Double(cards.count)
    }

    // MARK: - Loading

    /// Fetch a session. `extra` asks for another round on top of the day's
    /// work, which the server will always provide -- the daily limit paces how
    /// many *new* words arrive, it is not a cap on studying.
    func load(extra: Bool = false) async {
        phase = .loading
        guard settings.isConfigured else {
            phase = .failed("Set your server address and token in Settings.")
            return
        }
        let client = settings.makeClient()

        // Push anything queued from a previous offline session first, so the
        // queue we fetch reflects those reviews.
        pendingUpload = outbox.count
        if pendingUpload > 0 {
            await outbox.flush(using: client)
            pendingUpload = outbox.count
        }

        do {
            let queue = try await client.queue(extra: extra)
            isOffline = false
            // Only the day's queue is cached. It is what an offline session
            // should resume into: caching an extra round over it would hand
            // someone with no signal practice instead of the work that is due.
            if !extra { outbox.cacheQueue(queue) }
            start(with: queue)
        } catch let error as APIError where error.isTransient {
            // No signal: fall back to the last cached queue so the session can
            // still happen. Grades go to the outbox.
            isOffline = true
            if extra {
                // An extra round is drawn from the whole deck, and the whole
                // deck is on the server. There is nothing local to stand in.
                phase = .empty("Extra rounds need a connection. What's due is still here.")
            } else if let cached = outbox.cachedQueue() {
                start(with: cached)
            } else {
                phase = .empty("You're offline and there's nothing cached yet.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func start(with queue: StudyQueue) {
        cards = queue.cards
        isExtra = queue.extra
        deferred = []
        index = 0
        reviewedCount = 0
        typedAnswer = ""
        judgement = nil
        phase = cards.isEmpty
            ? .empty(
                queue.extra
                    ? "Nothing left to practise. Add some words."
                    : "Nothing due. Add some words, or come back later."
            )
            : .question
        speech.refreshVoiceStatus(for: settings.targetLang)
        autoplayIfNeeded()
    }

    // MARK: - Card flow

    /// Speak the prompt only when the prompt is in the target language.
    /// On a production or cloze card the audio is the answer.
    private func autoplayIfNeeded() {
        guard phase == .question, let card = current, card.audioAutoplay else { return }
        speech.speak(card.speechText, language: settings.targetLang)
    }

    func reveal() {
        guard let card = current, phase == .question else { return }
        phase = .revealed
        // Always speak on reveal, including the cards that stayed silent for
        // the question -- hearing it is the point.
        speech.speak(card.speechText, language: settings.targetLang)
    }

    func repeatAudio() {
        guard let card = current else { return }
        speech.speak(card.speechText, language: settings.targetLang)
    }

    /// Push the card to the end of the session without recording a grade.
    /// A skip is "not now", not "I forgot" -- grading it would feed FSRS a
    /// signal the learner never actually gave.
    func skip() {
        guard let card = current else { return }
        deferred.append(card)
        advance()
    }

    func grade(_ rating: Rating) {
        guard let card = current else { return }
        let mode = settings.speakingMode ? "speaking" : (card.kind.isTyped ? "typed" : "tapped")
        outbox.enqueue(cardId: card.cardId, rating: rating, mode: mode)
        pendingUpload = outbox.count
        reviewedCount += 1
        advance()
        Task { await self.uploadPending() }
    }

    private func advance() {
        speech.stop()
        typedAnswer = ""
        judgement = nil
        index += 1

        if index >= cards.count, !deferred.isEmpty {
            // Second pass over the skipped cards. Skipping rebuilds the order
            // the server carefully spaced, so space it again here -- and
            // against the tail of the run just finished, since the second pass
            // starts right after it.
            cards = Self.spacingSiblings(deferred, after: cards)
            deferred = []
            index = 0
        }

        phase = index < cards.count ? .question : .finished
        autoplayIfNeeded()
    }

    /// Reorder so no two cards of the same word land within `siblingGap` of
    /// each other, counting the tail of `seen` as already shown.
    ///
    /// A word's recognition and production cards are mirror images: answering
    /// "hei -> hi" and then meeting "hi -> hei" reads back the answer you were
    /// just shown, so the second card tests nothing.
    ///
    /// Greedy and order-preserving -- at each slot it takes the earliest card
    /// whose word has not come up recently. Best-effort by design: when
    /// everything left is a sibling it still shows them, because withholding a
    /// card the learner asked to see again is worse than showing it early.
    nonisolated static func spacingSiblings(
        _ cards: [StudyCard],
        after seen: [StudyCard] = [],
        gap: Int = siblingGap
    ) -> [StudyCard] {
        guard gap >= 1 else { return cards }
        var remaining = cards
        var window = seen.suffix(gap).map(\.wordId)
        var out: [StudyCard] = []
        out.reserveCapacity(cards.count)

        while !remaining.isEmpty {
            let recent = Set(window.suffix(gap))
            let pick = remaining.firstIndex { !recent.contains($0.wordId) } ?? 0
            let card = remaining.remove(at: pick)
            out.append(card)
            window.append(card.wordId)
        }
        return out
    }

    // MARK: - Typed answers

    func submitTypedAnswer() async {
        guard let card = current, !typedAnswer.isEmpty else { return }
        isJudging = true
        let grader = LocalGrader(
            client: settings.isConfigured ? settings.makeClient() : nil,
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang
        )
        let expected = card.clozeAnswer ?? card.answer
        judgement = await grader.judge(prompt: card.prompt, expected: expected, given: typedAnswer)
        isJudging = false
        reveal()
    }

    /// What the grade buttons should suggest after an automatic judgement.
    var suggestedRating: Rating? {
        switch judgement?.verdict {
        case .correct: .good
        case .close: .hard
        case .wrong: .again
        case nil: nil
        }
    }

    // MARK: - Upload

    func uploadPending() async {
        guard settings.isConfigured else { return }
        let cleared = await outbox.flush(using: settings.makeClient())
        pendingUpload = outbox.count
        if cleared > 0 { isOffline = false }
    }
}
