import AVFoundation
import Observation

/// Text-to-speech for the target language.
@Observable
@MainActor
final class SpeechService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    private(set) var isSpeaking = false
    /// True when the only voice available for the target language is the basic
    /// one. The compact voices are noticeably robotic, and mislearning
    /// pronunciation from them is worse than not hearing it at all -- so the
    /// UI offers a way to install a better one.
    private(set) var usingBasicVoice = false
    private(set) var hasNoVoice = false

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    private func configureAudioSession() {
        // `.playback` means the silent switch does not mute pronunciation --
        // otherwise the app is silently broken for anyone who keeps their
        // phone on silent, which is most people.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .spokenAudio, options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal: speech may still work, just without ducking.
        }
    }

    /// Pick the best installed voice for a BCP-47 code.
    ///
    /// Falls back from an exact match to any voice sharing the language, so a
    /// learner set to `es-ES` still hears Spanish if only `es-MX` is installed.
    func voice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let language = languageCode.split(separator: "-").first.map(String.init) ?? languageCode

        let exact = all.filter { $0.language == languageCode }
        let sameLanguage = all.filter { $0.language.hasPrefix(language) }
        let candidates = exact.isEmpty ? sameLanguage : exact

        // premium > enhanced > default
        return candidates.max { lhs, rhs in
            rank(lhs.quality) < rank(rhs.quality)
        }
    }

    private func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        default: 1
        }
    }

    func refreshVoiceStatus(for languageCode: String) {
        guard let chosen = voice(for: languageCode) else {
            hasNoVoice = true
            usingBasicVoice = false
            return
        }
        hasNoVoice = false
        usingBasicVoice = rank(chosen.quality) == 1
    }

    func speak(_ text: String, language: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice(for: language)
        // Slightly under default: learners need to hear word boundaries, and
        // native-speed TTS runs the words together.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
