import SwiftUI

/// One phrase, asked in whichever direction the session is running.
struct PhraseCardView: View {
    let phrase: Phrase
    let mode: PracticeMode
    let revealed: Bool
    let isSpeaking: Bool
    let judgement: Judgement?
    let isJudging: Bool
    let diff: AnswerDiff.Result?
    let sourceName: String
    let targetName: String
    @Binding var typedAnswer: String

    let onRepeat: () -> Void
    let onCheck: () -> Void
    let onShow: () -> Void
    let onSkip: () -> Void
    let onNext: () -> Void

    var speakingApplies: Bool = false
    var isListening: Bool = false
    var liveTranscript: String = ""
    var onStartListening: () -> Void = {}
    var onStopListening: () -> Void = {}

    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { face }
            Spacer(minLength: 12)
            controls
        }
    }

    // MARK: - Card face

    private var face: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(mode.title(source: sourceName, target: targetName), systemImage: mode.icon)
                    .foregroundStyle(.secondary)
                Spacer()
                if phrase.isReturning {
                    // A sentence only comes back because it was missed. Saying
                    // so is the difference between "here it is again" and the
                    // suspicion that the server is repeating itself.
                    Label("Missed before", systemImage: "arrow.trianglehead.counterclockwise")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.semibold))

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

    @ViewBuilder
    private var prompt: some View {
        if mode.promptIsAudio, !revealed {
            // The recording is the question. Any text at all would answer it.
            VStack(spacing: 10) {
                Image(systemName: isSpeaking ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: isSpeaking)
                Text(
                    mode == .dictation
                        ? "Write down what you hear."
                        : "What does it mean?"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Text(mode.prompt(for: phrase))
                .font(.system(.title2, design: .serif))
                .fontWeight(.medium)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var answer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phrase.target)
                    .font(.system(.title3, design: .serif))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Button(action: onRepeat) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play the sentence")
            }

            Text(phrase.native)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let judgement {
                judgementRow(judgement)
            }

            if let diff, !diff.isPerfect {
                diffRow(diff)
            }

            if !phrase.lemmas.isEmpty {
                // The deck words it was built from: a sentence you couldn't
                // finish should point at the words it was made of.
                Text("From your deck: \(phrase.lemmas.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
        .background(
            colour(for: judgement.verdict).opacity(0.10), in: RoundedRectangle(cornerRadius: 10)
        )
    }

    /// Which words went missing, marked on the sentence that was said.
    private func diffRow(_ diff: AnswerDiff.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word for word").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            diff.expected.reduce(Text("")) { line, token in
                line
                    + Text(token.text + " ")
                    .foregroundStyle(token.isMissed ? Color.orange : Color.primary)
                    .fontWeight(token.isMissed ? .bold : .regular)
            }
            .font(.callout)

            if !diff.extras.isEmpty {
                // A mishearing is a swap, and showing only the missing half of
                // it reads as though a word was left out.
                Text("You wrote \(diff.extras.joined(separator: ", ")) instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
            if revealed {
                Button(action: onNext) {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if speakingApplies {
                speakingControls
            } else {
                answerField
            }

            HStack(spacing: 12) {
                Button(action: onRepeat) {
                    Label("Repeat", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onSkip) {
                    Label("Skip", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var answerField: some View {
        VStack(spacing: 10) {
            // Whole sentences, so the field grows rather than scrolling a long
            // answer sideways out of view.
            TextField(
                mode.placeholder(source: sourceName, target: targetName),
                text: $typedAnswer,
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($answerFocused)
            .font(.title3)
            .onSubmit(onCheck)

            Button(action: onCheck) {
                if isJudging {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Check").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(typedAnswer.trimmingCharacters(in: .whitespaces).isEmpty || isJudging)

            Button("Show me", action: onShow).font(.footnote)
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
                if isJudging {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label(
                        isListening ? "Stop and check" : "Say it",
                        systemImage: isListening ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isListening ? .red : .accentColor)
            .disabled(isJudging)

            Button("Show me", action: onShow).font(.footnote)
        }
    }
}
