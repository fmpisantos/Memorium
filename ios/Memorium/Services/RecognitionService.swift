import AVFoundation
import Observation
import Speech

/// Speech recognition for speaking practice.
///
/// Recognition is requested on-device wherever the locale supports it: this is
/// a private study session, and it should keep working on a plane.
@Observable
@MainActor
final class RecognitionService {
    enum State: Equatable {
        case idle
        case denied(String)
        case listening
        case finished(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var isOnDevice = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            state = .denied("Speech recognition permission was declined.")
            return false
        }

        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard mic else {
            state = .denied("Microphone permission was declined.")
            return false
        }
        return true
    }

    func start(locale identifier: String) async {
        guard await authorize() else { return }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
              recognizer.isAvailable
        else {
            state = .denied("Speech recognition isn't available for \(identifier).")
            return
        }

        stop()
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            isOnDevice = true
        } else {
            isOnDevice = false
        }
        self.request = request

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker]
            )
            try AVAudioSession.sharedInstance().setActive(
                true, options: .notifyOthersOnDeactivation
            )
        } catch {
            state = .denied("Couldn't start the microphone.")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .denied("Couldn't start the microphone.")
            return
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish()
                    }
                }
                if error != nil {
                    self.finish()
                }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func finish() {
        stop()
        state = .finished(transcript)
        // Hand the audio session back so pronunciation playback isn't left
        // stuck in record mode.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    func reset() {
        stop()
        transcript = ""
        state = .idle
    }

    /// How close the transcription was, 0...1.
    ///
    /// Speech recognition is not a pronunciation scorer -- it reports what it
    /// thinks you said, and it silently corrects towards real words. Treat this
    /// as "was it recognisable", not "was it well pronounced", and keep the
    /// final judgement with the learner.
    nonisolated static func similarity(said: String, expected: String) -> Double {
        let a = LocalGrader.normalise(said)
        let b = LocalGrader.normalise(expected)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }

        let distance = levenshtein(Array(a), Array(b))
        return max(0, 1 - Double(distance) / Double(max(a.count, b.count)))
    }

    private nonisolated static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
