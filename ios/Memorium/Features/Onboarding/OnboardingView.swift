import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings

    @State private var serverURL = ""
    @State private var token = ""
    @State private var sourceLang = "en-US"
    @State private var targetLang = "es-ES"
    @State private var isTesting = false
    @State private var testResult: TestOutcome?

    enum TestOutcome {
        case success(HealthStatus)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("I speak", selection: $sourceLang) {
                        ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                    }
                    Picker("I'm learning", selection: $targetLang) {
                        ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text(
                        "This sets the pronunciation voice, which way round cards are asked, and the language Claude writes examples in. You can change it later."
                    )
                }

                Section {
                    TextField("http://192.168.1.10:8000", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API token", text: $token)
                } header: {
                    Text("Your server")
                } footer: {
                    Text(
                        "The token is the only thing protecting your deck, so keep the server on your home network or Tailscale rather than the open internet."
                    )
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(serverURL.isEmpty || token.isEmpty || isTesting)

                    switch testResult {
                    case let .success(health):
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if !health.claudeIsHealthy {
                            Label(
                                "Claude isn't authenticated on the server — cards will work, but examples won't generate.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    case let .failure(message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    case nil:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Set up Memorium")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { finish() }
                        .disabled(!isConnected)
                }
            }
            .onAppear {
                serverURL = settings.serverURL
                token = settings.apiToken
                sourceLang = settings.sourceLang
                targetLang = settings.targetLang
            }
        }
    }

    private var isConnected: Bool {
        if case .success = testResult { return true }
        return false
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }

        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil
        else {
            testResult = .failure("That doesn't look like a URL. Include http:// or https://")
            return
        }

        do {
            let health = try await APIClient(baseURL: url, token: token).health()
            testResult = .success(health)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    private func finish() {
        settings.serverURL = serverURL.trimmingCharacters(in: .whitespaces)
        settings.apiToken = token
        settings.sourceLang = sourceLang
        settings.targetLang = targetLang
        settings.hasOnboarded = true

        // Push the language pair to the server so generated content and the
        // deck agree on which way round the pair is.
        Task {
            try? await settings.makeClient().updateProfile(
                ProfileUpdate(
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    timezone: TimeZone.current.identifier
                )
            )
        }
    }
}
