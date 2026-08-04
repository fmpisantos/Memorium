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

    // Every system callback in this file is explicitly `@Sendable`. This class
    // is `@MainActor`, so a closure written inside it is inferred to be
    // MainActor-isolated -- and both permission callbacks and the audio tap are
    // documented to arrive on some other thread. Swift 6 checks that assumption
    // at runtime and traps, which crashed the app the instant "Say it" was
    // tapped. `@Sendable` makes them nonisolated, and they hop back explicitly.

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        guard speech == .authorized else {
            state = .denied("Speech recognition permission was declined.")
            return false
        }

        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable granted in
                continuation.resume(returning: granted)
            }
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
        // An input the route hasn't produced yet reports 0Hz / 0 channels, and
        // installing a tap with that format is a hard crash inside AVFAudio
        // rather than an error we could catch.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .denied("The microphone isn't available right now.")
            return
        }

        input.removeTap(onBus: 0)
        // Runs on the audio I/O thread: nonisolated by necessity. Appending
        // there is what SFSpeechAudioBufferRecognitionRequest is built for.
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .denied("Couldn't start the microphone.")
            return
        }

        state = .listening
        // Results land on `recognizer.queue`, which is the main queue by
        // default -- but that is a settable property, so this one is pinned
        // nonisolated too and only Sendable values cross to the main actor.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if ended { self.finish() }
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
        // stuck in record mode: `.measurement` turns off the output processing
        // TTS relies on, and it stays that way until the category is restored.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, options: [.duckOthers]
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
