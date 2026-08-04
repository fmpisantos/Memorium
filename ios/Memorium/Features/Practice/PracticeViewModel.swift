import Foundation
import Observation
import SwiftData

/// A run through a set of phrases in one of the four directions.
///
/// Deliberately outside the schedule. Cards carry the deck's memory and this
/// does not touch it: getting a sentence wrong here means the sentence was
/// hard, not that a word needs reviewing sooner, and feeding that into FSRS
/// would let a bad evening's listening reschedule vocabulary that is fine.
@Observable
@MainActor
final class PracticeViewModel {
    enum Phase: Equatable {
        case loading
        case question
        case revealed
        case finished
        case empty(String)
        case failed(String)
    }

    /// A session's worth. Long enough to settle into, short enough to finish.
    static let sessionSize = 10

    private(set) var phase: Phase = .loading
    private(set) var phrases: [Phrase] = []
    private(set) var index = 0
    private(set) var answered = 0
    private(set) var correct = 0
    private(set) var isOffline = false

    var typedAnswer = ""
    private(set) var judgement: Judgement?
    private(set) var isJudging = false
    /// Word-by-word feedback, on a dictation only. See `AnswerDiff`.
    private(set) var diff: AnswerDiff.Result?

    let recogniser = RecognitionService()

    private let settings: AppSettings
    private let speech: SpeechService
    private let store: PhraseStore

    init(settings: AppSettings, speech: SpeechService, context: ModelContext) {
        self.settings = settings
        self.speech = speech
        self.store = PhraseStore(context: context)
    }

    // MARK: - Mode

    /// Changing direction restarts the run over the same sentences rather than
    /// fetching new ones: hearing a phrase and then having to produce it is a
    /// perfectly good second pass, and it costs nothing.
    var mode: PracticeMode {
        get { settings.practiceMode }
        set {
            guard newValue != settings.practiceMode else { return }
            settings.practiceMode = newValue
            restart()
        }
    }

    var sourceName: String { LanguageOption.shortName(for: settings.sourceLang) }
    var targetName: String { LanguageOption.shortName(for: settings.targetLang) }

    var current: Phrase? {
        guard index < phrases.count else { return nil }
        return phrases[index]
    }

    var progress: Double {
        phrases.isEmpty ? 0 : Double(index) / Double(phrases.count)
    }

    /// The answer as it should have been -- what the grade was against.
    var expected: String { current.map { mode.expected(for: $0) } ?? "" }

    /// Speaking replaces typing when it is switched on in Settings. It applies
    /// in every direction here: the answer is a whole sentence either way, and
    /// saying one is the skill this screen exists to build.
    var speakingApplies: Bool { settings.speakingMode }

    /// Which voice transcribes a spoken answer -- the language the answer is
    /// in, not the one the sentence was written in.
    var answerLocale: String {
        mode.answerIsTarget ? settings.targetLang : settings.sourceLang
    }

    // MARK: - Loading

    /// Fetch a session.
    ///
    /// Results are pushed first. The server decides which sentences to send
    /// back and it decides on what it knows: flushing afterwards would fetch a
    /// set chosen as if last night's session never happened, and hand back the
    /// sentences that were already answered.
    ///
    /// `refresh` asks for material never served before, rather than the
    /// unfinished business that normally comes first.
    func load(refresh: Bool = false) async {
        phase = .loading
        guard settings.isConfigured else {
            phase = .failed("Set your server address in Settings.")
            return
        }

        do {
            let client = settings.makeClient()
            await store.flushResults(using: client)
            let set = try await client.phrases(count: Self.sessionSize, refresh: refresh)
            isOffline = false
            store.cache(set)
            start(with: set.phrases)
        } catch let APIError.server(status, detail) where status == 409 {
            // Not a failure: the deck simply isn't big enough to build
            // sentences out of yet, and the server says so in words.
            phase = .empty(detail)
        } catch let error as APIError where error.isTransient {
            isOffline = true
            if let cached = store.cached()?.phrases, !cached.isEmpty {
                start(with: cached)
            } else {
                phase = .empty(
                    "Phrases are written on the server, and it can't be reached. "
                        + "The last set you practised would be here if there were one."
                )
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func start(with phrases: [Phrase]) {
        self.phrases = phrases
        index = 0
        answered = 0
        correct = 0
        clearAnswer()
        phase = phrases.isEmpty ? .empty("No phrases came back. Try again in a moment.") : .question
        speech.refreshVoiceStatus(for: settings.targetLang)
        playPromptIfNeeded()
    }

    /// Same sentences, from the top. Used when the direction changes.
    private func restart() {
        guard !phrases.isEmpty else { return }
        index = 0
        answered = 0
        correct = 0
        clearAnswer()
        phase = .question
        playPromptIfNeeded()
    }

    // MARK: - The run

    /// Speak the sentence as the question arrives -- but never on a card whose
    /// answer is the target language, where the audio *is* the answer.
    private func playPromptIfNeeded() {
        guard phase == .question, let phrase = current, mode.playsPromptAudio else { return }
        speech.speak(phrase.target, language: settings.targetLang)
    }

    func repeatAudio() {
        guard let phrase = current else { return }
        speech.speak(phrase.target, language: settings.targetLang)
    }

    /// Give up on this one. No judgement is recorded: not knowing an answer you
    /// never gave is not the same as getting it wrong, and the session score is
    /// only worth reading if it counts attempts.
    func revealWithoutAnswering() {
        guard phase == .question else { return }
        // A recording still running would hold the audio session in record
        // mode, and the sentence about to be spoken would come out flat.
        recogniser.stop()
        reveal()
    }

    private func reveal() {
        guard let phrase = current else { return }
        phase = .revealed
        // Always spoken on reveal, including in the direction that stayed
        // silent for the question -- hearing the sentence is half the point.
        speech.speak(phrase.target, language: settings.targetLang)
    }

    func skip() {
        guard current != nil else { return }
        advance()
    }

    func next() {
        advance()
    }

    private func advance() {
        speech.stop()
        clearAnswer()
        index += 1
        phase = index < phrases.count ? .question : .finished
        playPromptIfNeeded()
        if phase == .finished { Task { await flushResults() } }
    }

    /// Tell the server how the session went.
    ///
    /// Nothing here is urgent enough to make the learner wait for it, and
    /// nothing is lost if it fails: results sit on the device until they land,
    /// and the next `load` tries again before asking for a new set.
    private func flushResults() async {
        guard settings.isConfigured else { return }
        await store.flushResults(using: settings.makeClient())
    }

    private func clearAnswer() {
        typedAnswer = ""
        judgement = nil
        diff = nil
        recogniser.reset()
    }

    // MARK: - Answering

    func check() async {
        guard let phrase = current, phase == .question else { return }
        let given = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty else { return }

        isJudging = true
        let grader = LocalGrader(
            client: settings.isConfigured ? settings.makeClient() : nil,
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang
        )
        let expected = mode.expected(for: phrase)
        let verdict = await grader.judge(
            prompt: mode.prompt(for: phrase),
            expected: expected,
            given: given,
            kind: mode.gradeKind
        )
        isJudging = false

        judgement = verdict
        // Which word went missing is the whole question in a dictation, and it
        // is a string comparison rather than anything needing a connection.
        diff = mode.showsWordDiff ? AnswerDiff.compare(expected: expected, given: given) : nil

        answered += 1
        let right = verdict.verdict == .correct
        if right { correct += 1 }
        // Recorded on the device first, and sent when the session ends. Only a
        // right answer retires a sentence: "close" comes back, because close
        // is what you get when you nearly know it.
        store.record(phraseId: phrase.id, correct: right)
        reveal()
    }

    // MARK: - Speaking the answer

    func startListening() async {
        speech.stop()
        recogniser.reset()
        await recogniser.start(locale: answerLocale)
    }

    /// Stop recording and grade what was heard.
    ///
    /// The transcript goes through the same three tiers a typed answer does,
    /// rather than being scored on how close the letters are: "I need water"
    /// for "I need some water" is a fine answer to a translation and a poor
    /// one to a dictation, and only a grader that knows which was asked can
    /// tell those apart.
    func stopListening() async {
        recogniser.stop()
        typedAnswer = recogniser.transcript
        guard !typedAnswer.trimmingCharacters(in: .whitespaces).isEmpty else {
            judgement = Judgement(
                verdict: .wrong, reason: "Didn't catch anything.", source: .onDevice
            )
            reveal()
            return
        }
        await check()
    }

    var isListening: Bool { recogniser.state == .listening }

    /// What the session came to. Only counted attempts appear here -- see
    /// `revealWithoutAnswering`.
    var summary: String {
        guard answered > 0 else { return "Nothing answered this time." }
        return "\(correct) of \(answered) right."
    }
}
