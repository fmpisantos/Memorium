import SwiftData
import SwiftUI

/// Whole sentences, built from words already in the deck.
///
/// The cards teach one word at a time. This is where those words have to turn
/// up in a sentence you only heard, or one you have to produce from your own
/// language -- which is the difference between knowing a word and being able
/// to reach for it.
struct PracticeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechService.self) private var speech
    @Environment(\.modelContext) private var context

    @State private var model: PracticeViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Phrases")
            .toolbar {
                if let model {
                    ToolbarItem(placement: .topBarTrailing) { modeMenu(model) }
                }
            }
        }
        .task {
            if model == nil {
                model = PracticeViewModel(settings: settings, speech: speech, context: context)
                await model?.load()
            }
        }
    }

    /// The direction is a menu rather than a screen of its own: it is one
    /// choice, it is worth changing mid-session, and doing so keeps the same
    /// sentences.
    private func modeMenu(_ model: PracticeViewModel) -> some View {
        @Bindable var model = model
        return Menu {
            Picker("Direction", selection: $model.mode) {
                ForEach(PracticeMode.allCases) { mode in
                    Label(
                        mode.title(source: model.sourceName, target: model.targetName),
                        systemImage: mode.icon
                    )
                    .tag(mode)
                }
            }
            Divider()
            Button("New phrases", systemImage: "sparkles") {
                Task { await model.load(refresh: true) }
            }
        } label: {
            Label("Direction", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private func content(_ model: PracticeViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Writing your phrases…")

        case .question, .revealed:
            if let phrase = model.current {
                VStack(spacing: 16) {
                    header(model)
                    PhraseCardView(
                        phrase: phrase,
                        mode: model.mode,
                        revealed: model.phase == .revealed,
                        isSpeaking: speech.isSpeaking,
                        judgement: model.judgement,
                        isJudging: model.isJudging,
                        diff: model.diff,
                        sourceName: model.sourceName,
                        targetName: model.targetName,
                        typedAnswer: Binding(
                            get: { model.typedAnswer },
                            set: { model.typedAnswer = $0 }
                        ),
                        onRepeat: model.repeatAudio,
                        onCheck: { Task { await model.check() } },
                        onShow: model.revealWithoutAnswering,
                        onSkip: model.skip,
                        onNext: model.next,
                        speakingApplies: model.speakingApplies,
                        isListening: model.isListening,
                        liveTranscript: model.recogniser.transcript,
                        onStartListening: { Task { await model.startListening() } },
                        onStopListening: { Task { await model.stopListening() } }
                    )
                    .id(phrase.id)
                }
                .padding()
            }

        case .finished:
            ContentUnavailableView {
                Label("Session done", systemImage: "checkmark.seal.fill")
            } description: {
                Text(model.summary)
            } actions: {
                againButtons(model)
            }

        case let .empty(message):
            ContentUnavailableView {
                Label("Nothing to practise yet", systemImage: "text.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't load your phrases", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func header(_ model: PracticeViewModel) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: model.progress)
            HStack {
                Text("\(model.index + 1) of \(model.phrases.count)")
                if model.answered > 0 {
                    Text("· \(model.correct)/\(model.answered) right")
                }
                Spacer()
                if model.isOffline {
                    Label("Offline — practising the last set", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
                if speech.hasNoVoice {
                    // Worth saying loudly here: two of the four directions are
                    // nothing but audio.
                    Label("No voice installed", systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func againButtons(_ model: PracticeViewModel) -> some View {
        VStack(spacing: 8) {
            Button("More phrases") { Task { await model.load() } }
                .buttonStyle(.borderedProminent)
            Button("Write me new ones") { Task { await model.load(refresh: true) } }
                .buttonStyle(.bordered)
        }
    }
}
