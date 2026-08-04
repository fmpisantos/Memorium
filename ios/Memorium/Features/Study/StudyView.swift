import SwiftData
import SwiftUI

struct StudyView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechService.self) private var speech
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: StudyViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Study")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let model, model.pendingUpload > 0 {
                        Label("\(model.pendingUpload)", systemImage: "arrow.up.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(model.pendingUpload) reviews waiting to upload")
                    }
                }
            }
        }
        .task {
            if model == nil {
                model = StudyViewModel(settings: settings, speech: speech, context: context)
            }
            await model?.load()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the most likely moment for the network
            // to have returned.
            if phase == .active { Task { await model?.uploadPending() } }
        }
    }

    @ViewBuilder
    private func content(_ model: StudyViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading your queue…")

        case .question, .revealed:
            if let card = model.current {
                VStack(spacing: 16) {
                    header(model)
                    CardView(
                        card: card,
                        revealed: model.phase == .revealed,
                        isSpeaking: speech.isSpeaking,
                        judgement: model.judgement,
                        isJudging: model.isJudging,
                        typedAnswer: Binding(
                            get: { model.typedAnswer },
                            set: { model.typedAnswer = $0 }
                        ),
                        onShow: model.reveal,
                        onRepeat: model.repeatAudio,
                        onSkip: model.skip,
                        onSubmitTyped: { Task { await model.submitTypedAnswer() } },
                        onGrade: model.grade,
                        suggestedRating: model.suggestedRating,
                        speakingApplies: model.speakingApplies,
                        isListening: model.recogniser.state == .listening,
                        liveTranscript: model.recogniser.transcript,
                        onStartListening: { Task { await model.startListening() } },
                        onStopListening: model.stopListening
                    )
                    .id(card.cardId)
                }
                .padding()
            }

        case .finished:
            finished(model)

        case let .empty(message):
            ContentUnavailableView {
                Label("All caught up", systemImage: "checkmark.circle")
            } description: {
                Text(message)
            } actions: {
                moreButtons(model)
            }

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't load your queue", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func header(_ model: StudyViewModel) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: model.progress)
            HStack {
                Text("\(model.index + 1) of \(model.cards.count)")
                if model.isExtra {
                    // Worth saying: answering a card early here deliberately
                    // leaves its next review date alone.
                    Text("· extra")
                }
                Spacer()
                if model.isOffline {
                    Label("Offline — saved on device", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
                if speech.hasNoVoice {
                    Label("No voice installed", systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func finished(_ model: StudyViewModel) -> some View {
        ContentUnavailableView {
            Label("Session done", systemImage: "checkmark.seal.fill")
        } description: {
            Text(
                model.reviewedCount == 0
                    ? "Nothing reviewed this time."
                    : "You reviewed \(model.reviewedCount) card\(model.reviewedCount == 1 ? "" : "s")."
            )
        } actions: {
            moreButtons(model)
        }
    }

    /// Finishing a session is never a locked door. The daily goal paces how
    /// many new words arrive; carrying on is always one tap away, and the
    /// extra round is drawn at random so it can't be learned as a sequence.
    @ViewBuilder
    private func moreButtons(_ model: StudyViewModel) -> some View {
        VStack(spacing: 8) {
            Button("Keep going") { Task { await model.load(extra: true) } }
                .buttonStyle(.borderedProminent)
            Button("Check what's due") { Task { await model.load() } }
                .buttonStyle(.bordered)
        }
    }
}
