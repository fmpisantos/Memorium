import SwiftUI
#if canImport(Translation)
    import Translation
#endif

/// Reports whether the current language pair translates on device, and offers
/// the system download when Apple has the pair but it isn't installed yet.
///
/// Downloading is the one part of the Translation framework that still needs a
/// view. `prepareTranslation()` presents a system consent sheet, so it has to be
/// reached through `.translationTask` rather than from `LocalTranslator`, which
/// is why this is a `View` and not another method on the service.
struct TranslationDownloadRow: View {
    let sourceLang: String
    let targetLang: String

    /// Which half of the pair the download is on. Cards are filled in both
    /// directions, so both are prepared -- forward, then back -- and the two
    /// cases here are what bounds that at exactly two passes.
    private enum Step {
        case idle, forward, reverse
    }

    @State private var status: OnDeviceTranslation?
    @State private var step: Step = .idle
    #if canImport(Translation)
        @State private var configuration: TranslationSession.Configuration?
    #endif

    var body: some View {
        downloadable
            .task(id: "\(sourceLang)|\(targetLang)") { await refresh() }
    }

    #if canImport(Translation)
        private var downloadable: some View {
            rows.translationTask(configuration) { session in
                // `prepareTranslation()` is `nonisolated async` in an SDK built
                // before Swift 6.2's caller-isolation defaults, so it hops off
                // the main actor -- and `TranslationSession` isn't Sendable, so
                // the hand-off is a strict-concurrency error. The modifier hands
                // this session to nobody else and we drop it on the next line,
                // so there is no second user to race with.
                nonisolated(unsafe) let session = session
                // A pair that is already installed returns immediately, so the
                // reverse pass is free when one download covered both.
                try? await session.prepareTranslation()

                switch step {
                case .forward:
                    step = .reverse
                    configuration = Self.configuration(from: targetLang, to: sourceLang)
                case .reverse, .idle:
                    step = .idle
                    await refresh()
                }
            }
        }
    #else
        private var downloadable: some View { rows }
    #endif

    @ViewBuilder
    private var rows: some View {
        switch status {
        case .ready:
            Label("Available offline", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .needsDownload:
            Button(action: prepare) {
                if step == .idle {
                    Label("Download language pair", systemImage: "arrow.down.circle")
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading…")
                    }
                }
            }
            .disabled(step != .idle)

        case let .unsupported(reason):
            Label(reason, systemImage: "iphone.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("New words will be translated by the server instead.")
                .font(.caption)
                .foregroundStyle(.tertiary)

        case nil:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        status = await LocalTranslator.pairStatus(source: sourceLang, target: targetLang)
    }

    private func prepare() {
        #if canImport(Translation)
            step = .forward
            configuration = Self.configuration(from: sourceLang, to: targetLang)
        #endif
    }

    #if canImport(Translation)
        private static func configuration(
            from: String, to: String
        ) -> TranslationSession.Configuration {
            TranslationSession.Configuration(
                source: Locale.Language(identifier: from),
                target: Locale.Language(identifier: to)
            )
        }
    #endif
}
