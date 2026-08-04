import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechService.self) private var speech
    @Environment(AuthService.self) private var auth

    @State private var health: HealthStatus?
    @State private var enrichment: EnrichStatus?
    @State private var dailyNewLimit = 10
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Languages") {
                    Picker("I speak", selection: $settings.sourceLang) {
                        ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                    }
                    Picker("I'm learning", selection: $settings.targetLang) {
                        ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                    }
                }
                .onChange(of: settings.targetLang) { _, new in
                    speech.refreshVoiceStatus(for: new)
                    pushProfile()
                }
                .onChange(of: settings.sourceLang) { _, _ in pushProfile() }

                voiceSection

                Section {
                    Stepper("New words per day: \(dailyNewLimit)", value: $dailyNewLimit, in: 0 ... 60)
                        .onChange(of: dailyNewLimit) { _, _ in pushProfile() }
                    Toggle("Answer by speaking", isOn: $settings.speakingMode)
                } header: {
                    Text("Study")
                } footer: {
                    Text(
                        "Reviews are never capped — only how many brand-new words get introduced. Raising this raises tomorrow's review load too."
                    )
                }

                Section {
                    Toggle("Translate automatically", isOn: $settings.autoTranslate)
                } header: {
                    Text("Adding words")
                } footer: {
                    Text(
                        "Fill in either side of a new word and the other is translated for you. Off, the add sheet still offers a translate button beside each field."
                    )
                }

                serverSection

                Section("On-device grading") {
                    if let reason = LocalGrader.onDeviceAvailability {
                        Label(reason, systemImage: "iphone.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Typed answers will be checked by the server instead.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Label("Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    TranslationDownloadRow(
                        sourceLang: settings.sourceLang,
                        targetLang: settings.targetLang
                    )
                } header: {
                    Text("On-device translation")
                } footer: {
                    Text(
                        "Downloaded pairs are translated on the phone — instantly, offline, and without a request. Everything else falls back to the server."
                    )
                }

                Section {
                    LabeledContent("Address", value: settings.serverURL)
                        .textSelection(.enabled)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Built into the app — MEMORIUM_API_URL in ios/project.yml.")
                }

                Section {
                    LabeledContent("Signed in as", value: auth.email ?? "nobody")
                    Button("Sign out", role: .destructive) { auth.signOut() }
                } header: {
                    Text("Account")
                } footer: {
                    Text(
                        "Your server checks this address against its own allowed list on every request. Signing out here leaves the deck on the server untouched."
                    )
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            if speech.hasNoVoice {
                Label(
                    "No voice installed for \(LanguageOption.name(for: settings.targetLang))",
                    systemImage: "speaker.slash.fill"
                )
                .foregroundStyle(.orange)
            } else if speech.usingBasicVoice {
                Label("Using the basic voice", systemImage: "speaker.wave.1")
                    .foregroundStyle(.orange)
            } else {
                Label("Enhanced voice installed", systemImage: "speaker.wave.3.fill")
                    .foregroundStyle(.green)
            }

            Button("Hear a sample") {
                speech.speak(sampleText, language: settings.targetLang)
            }
        } header: {
            Text("Pronunciation")
        } footer: {
            if speech.usingBasicVoice || speech.hasNoVoice {
                Text(
                    "The built-in compact voices are robotic enough to teach you the wrong pronunciation. Install a better one in Settings → Accessibility → Spoken Content → Voices."
                )
            }
        }
    }

    private var sampleText: String {
        switch settings.targetLang.prefix(2) {
        case "es": "El perro corre por el parque."
        case "fr": "Le chien court dans le parc."
        case "de": "Der Hund läuft durch den Park."
        case "pt": "O cão corre pelo parque."
        case "it": "Il cane corre nel parco."
        case "nb", "no": "Hunden løper i parken."
        case "sv": "Hunden springer i parken."
        case "da": "Hunden løber i parken."
        case "nl": "De hond rent door het park."
        default: "Hello, this is a pronunciation sample."
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            if let health {
                LabeledContent("Status", value: health.status)
                LabeledContent("Database", value: health.db)
                HStack {
                    Text("Claude")
                    Spacer()
                    if health.claudeIsHealthy {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not authenticated", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !health.claudeIsHealthy {
                    Text(
                        "Run `claude setup-token` on the server and restart it. Studying still works; new words just won't get examples."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Label("Not reachable", systemImage: "wifi.slash").foregroundStyle(.secondary)
            }

            if let enrichment {
                LabeledContent("Examples generated", value: "\(enrichment.done)")
                if enrichment.pending + enrichment.running > 0 {
                    LabeledContent(
                        "In progress", value: "\(enrichment.pending + enrichment.running)"
                    )
                }
                if enrichment.failed > 0 {
                    Button("Retry \(enrichment.failed) failed") {
                        Task {
                            // Failures only -- the button counted those, and
                            // re-running the pending ones as well would report
                            // a number the learner never saw.
                            _ = try? await settings.makeClient().retryFailedEnrichments()
                            await refresh()
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func refresh() async {
        guard settings.isConfigured else { return }
        let client = settings.makeClient()
        health = try? await client.health()
        enrichment = try? await client.enrichmentStatus()
        if let profile = try? await client.profile() {
            dailyNewLimit = profile.dailyNewLimit
        }
        speech.refreshVoiceStatus(for: settings.targetLang)
    }

    private func pushProfile() {
        Task {
            guard settings.isConfigured else { return }
            do {
                _ = try await settings.makeClient().updateProfile(
                    ProfileUpdate(
                        sourceLang: settings.sourceLang,
                        targetLang: settings.targetLang,
                        dailyNewLimit: dailyNewLimit,
                        timezone: TimeZone.current.identifier
                    )
                )
                message = nil
            } catch {
                message = "Couldn't save to the server: \(error.localizedDescription)"
            }
        }
    }
}
