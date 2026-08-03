import SwiftUI

struct CardView: View {
    let card: StudyCard
    let revealed: Bool
    let isSpeaking: Bool
    let judgement: Judgement?
    let isJudging: Bool
    @Binding var typedAnswer: String

    let onShow: () -> Void
    let onRepeat: () -> Void
    let onSkip: () -> Void
    let onSubmitTyped: () -> Void
    let onGrade: (Rating) -> Void
    let suggestedRating: Rating?

    // Speaking practice
    var speakingApplies: Bool = false
    var isListening: Bool = false
    var liveTranscript: String = ""
    var onStartListening: () -> Void = {}
    var onStopListening: () -> Void = {}

    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            face
            Spacer(minLength: 12)
            controls
        }
    }

    // MARK: - Card face

    private var face: some View {
        VStack(spacing: 18) {
            HStack {
                Label(card.kind.title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if card.isNew {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if card.isLeech {
                    Label("Tricky", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            prompt

            if revealed {
                Divider()
                answer
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary))
    }

    private var icon: String {
        switch card.kind {
        case .recognition: "eye"
        case .production: "pencil.and.outline"
        case .listening: "ear"
        case .cloze: "text.insert"
        }
    }

    @ViewBuilder
    private var prompt: some View {
        if card.kind == .listening, !revealed {
            // Audio *is* the question. Showing the word would defeat it.
            VStack(spacing: 10) {
                Image(systemName: isSpeaking ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: isSpeaking)
                Text("What did you hear?")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Text(card.prompt)
                .font(.system(.largeTitle, design: .serif))
                .fontWeight(.medium)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if card.kind == .cloze, !revealed {
            Text(card.nativeGloss)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var answer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.answer)
                    .font(.system(.title, design: .serif))
                    .fontWeight(.semibold)
                Button(action: onRepeat) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play pronunciation")
            }

            if let judgement {
                judgementRow(judgement)
            }

            if let target = card.sentenceTarget, !target.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target).font(.callout).italic()
                    if let native = card.sentenceNative {
                        Text(native).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            if let pos = card.pos, !pos.isEmpty {
                Text(pos).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func judgementRow(_ judgement: Judgement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: judgement.verdict))
                .foregroundStyle(colour(for: judgement.verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text(judgement.reason).font(.footnote)
                Text("checked \(judgement.source.rawValue)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour(for: judgement.verdict).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(for verdict: AnswerVerdict) -> String {
        switch verdict {
        case .correct: "checkmark.circle.fill"
        case .close: "exclamationmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        }
    }

    private func colour(for verdict: AnswerVerdict) -> Color {
        switch verdict {
        case .correct: .green
        case .close: .orange
        case .wrong: .red
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 14) {
            if !revealed {
                if speakingApplies {
                    speakingControls
                } else if card.kind.isTyped {
                    TextField("Type the missing word", text: $typedAnswer)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($answerFocused)
                        .onSubmit(onSubmitTyped)
                        .font(.title3)

                    Button(action: onSubmitTyped) {
                        if isJudging {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Check").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(typedAnswer.isEmpty || isJudging)
                } else {
                    Button(action: onShow) {
                        Text("Show").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                gradeButtons
            }

            // Repeat sits before Skip, as specified.
            HStack(spacing: 12) {
                Button(action: onRepeat) {
                    Label("Repeat", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onSkip) {
                    Label("Skip", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var speakingControls: some View {
        VStack(spacing: 10) {
            if !liveTranscript.isEmpty {
                Text(liveTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button {
                isListening ? onStopListening() : onStartListening()
            } label: {
                Label(
                    isListening ? "Stop and check" : "Say it",
                    systemImage: isListening ? "stop.circle.fill" : "mic.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isListening ? .red : .accentColor)

            Button("Show instead", action: onShow)
                .font(.footnote)
        }
    }

    private var gradeButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Rating.allCases, id: \.self) { rating in
                    Button {
                        onGrade(rating)
                    } label: {
                        Text(rating.label)
                            .font(.callout.weight(suggestedRating == rating ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(tint(for: rating))
                }
            }
            .controlSize(.large)

            if suggestedRating != nil {
                Text("Suggested from the check above — override it if you disagree.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tint(for rating: Rating) -> Color {
        switch rating {
        case .again: .red
        case .hard: .orange
        case .good: .accentColor
        case .easy: .green
        }
    }
}
