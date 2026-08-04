import Foundation

/// The four ways a phrase can be asked.
///
/// One sentence, both sides of it, and a choice about which side is the
/// question and which language the answer is in. Keeping that choice here --
/// as plain functions over a `Phrase` -- is what stops the answer the learner
/// is graded against drifting away from the question they were actually asked.
enum PracticeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Hear it, write it down. No text, same language.
    case dictation
    /// Hear it, write what it means.
    case listenAndTranslate
    /// Read your own language, produce the one you're learning.
    case intoTarget
    /// Read the one you're learning, say what it means.
    case intoNative

    var id: String { rawValue }

    // MARK: - What is asked

    /// The text on the question side, or "" when the audio *is* the question.
    func prompt(for phrase: Phrase) -> String {
        switch self {
        case .dictation, .listenAndTranslate: ""
        case .intoTarget: phrase.native
        case .intoNative: phrase.target
        }
    }

    /// What the learner has to produce.
    func expected(for phrase: Phrase) -> String {
        switch self {
        case .dictation: phrase.target
        case .listenAndTranslate, .intoNative: phrase.native
        case .intoTarget: phrase.target
        }
    }

    /// True when nothing is shown and the recording is the whole question.
    var promptIsAudio: Bool {
        self == .dictation || self == .listenAndTranslate
    }

    /// Whether the sentence is spoken as the question arrives.
    ///
    /// The same rule the cards use: audio plays up front only when the prompt
    /// is already in the target language. On `intoTarget` the prompt is in the
    /// learner's own language and the target audio *is* the answer -- playing
    /// it would read the answer out before they tried.
    var playsPromptAudio: Bool { self != .intoTarget }

    /// True when the answer is in the language being learned. Decides which
    /// voice transcribes a spoken answer, and whether speaking is worth
    /// offering at all.
    var answerIsTarget: Bool {
        self == .dictation || self == .intoTarget
    }

    /// How the answer should be marked. A dictation has exactly one right
    /// answer; a translation has many.
    var gradeKind: GradeKind {
        self == .dictation ? .dictation : .sentence
    }

    /// Only a dictation gets a word-by-word diff -- see `AnswerDiff`.
    var showsWordDiff: Bool { self == .dictation }

    // MARK: - Naming

    var icon: String {
        switch self {
        case .dictation: "ear.badge.waveform"
        case .listenAndTranslate: "ear"
        case .intoTarget: "arrow.right.circle"
        case .intoNative: "arrow.left.circle"
        }
    }

    func title(source: String, target: String) -> String {
        switch self {
        case .dictation: "Write what you hear"
        case .listenAndTranslate: "Hear it, then translate"
        case .intoTarget: "\(source) → \(target)"
        case .intoNative: "\(target) → \(source)"
        }
    }

    func detail(source: String, target: String) -> String {
        switch self {
        case .dictation:
            "Audio only. Write the \(target) down exactly as you heard it."
        case .listenAndTranslate:
            "Audio only. Write what it means in \(source)."
        case .intoNative:
            "Read the \(target). Write what it means in \(source)."
        case .intoTarget:
            "Read the \(source). Write or say it in \(target)."
        }
    }

    /// What to put in an empty answer field.
    func placeholder(source: String, target: String) -> String {
        answerIsTarget ? "Write it in \(target)" : "Write it in \(source)"
    }
}
