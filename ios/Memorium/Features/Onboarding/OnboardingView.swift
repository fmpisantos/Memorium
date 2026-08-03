import GoogleSignInSwift
import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AuthService.self) private var auth

    @State private var serverURL = ""
    @State private var sourceLang = "en-US"
    @State private var targetLang = "es-ES"
    @State private var isTesting = false
    @State private var testResult: TestOutcome?
    @State private var isSigningIn = false
    @State private var signInError: String?
    /// The address the server confirmed it will accept.
    @State private var acceptedEmail: String?

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

                serverSection
                accountSection
            }
            .navigationTitle("Set up Memorium")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { finish() }
                        .disabled(acceptedEmail == nil)
                }
            }
            .onAppear {
                serverURL = settings.serverURL
                sourceLang = settings.sourceLang
                targetLang = settings.targetLang
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("http://192.168.1.10:8000", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: serverURL) { _, _ in
                    // A different server has a different allowlist.
                    testResult = nil
                    acceptedEmail = nil
                }

            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                }
            }
            .disabled(serverURL.isEmpty || isTesting)

            switch testResult {
            case let .success(health):
                Label("Reachable", systemImage: "checkmark.circle.fill")
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
        } header: {
            Text("Your server")
        } footer: {
            Text(
                "Keep the server on your home network or Tailscale rather than the open internet."
            )
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if !auth.isConfigured {
                Label(
                    "This build has no Google client ID yet. Set GOOGLE_CLIENT_ID and GOOGLE_REVERSED_CLIENT_ID in ios/project.yml, then run xcodegen generate.",
                    systemImage: "wrench.and.screwdriver"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if let acceptedEmail {
                Label(acceptedEmail, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                useAnotherAccountButton
            } else if auth.isSignedIn {
                // Signed in with Google, but the server hasn't confirmed the
                // account. Retrying that is not worth another trip to Google.
                LabeledContent("Signed in as", value: auth.email ?? "")
                Button("Ask the server again") { Task { await confirmWithServer() } }
                    .disabled(isSigningIn)
                useAnotherAccountButton
            } else {
                GoogleSignInButton { Task { await signIn() } }
                    .disabled(isSigningIn || !isReachable)
                    .opacity(isReachable ? 1 : 0.5)

                if isSigningIn {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking with your server…").font(.footnote)
                    }
                }
            }

            if let signInError {
                Label(signInError, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Your account")
        } footer: {
            Text(
                isReachable
                    ? "Your server only answers to the addresses in its MEMORIUM_ALLOWED_EMAILS list. Nothing to copy or paste — signing in is the whole of it."
                    : "Test the connection first."
            )
        }
    }

    private var useAnotherAccountButton: some View {
        Button("Use a different account") {
            auth.signOut()
            acceptedEmail = nil
            signInError = nil
        }
    }

    // MARK: - Actions

    private var isReachable: Bool {
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
            // /health needs no identity, which is what makes it usable here:
            // it separates "wrong address" from "not allowed in".
            testResult = .success(try await APIClient.anonymous(baseURL: url).health())
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    private func signIn() async {
        signInError = nil
        do {
            _ = try await auth.signIn()
        } catch {
            signInError = error.localizedDescription
            return
        }
        await confirmWithServer()
    }

    /// Signing in with Google is not the same as being allowed in. Asking the
    /// server here is what turns "not on the list" into one sentence naming
    /// the account, rather than every screen quietly failing to load later.
    private func confirmWithServer() async {
        isSigningIn = true
        defer { isSigningIn = false }
        signInError = nil

        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else { return }
        do {
            acceptedEmail = try await APIClient(baseURL: url) {
                try await AuthService.shared.idToken()
            }.me()
        } catch let APIError.notAllowed(detail) {
            // The account itself is the problem, so drop it: signing in again
            // with the same one would only fail the same way.
            acceptedEmail = nil
            signInError = detail
            auth.signOut()
        } catch {
            // Offline, or the server is down. The sign-in was fine and is
            // worth keeping -- retrying should not mean signing in again.
            acceptedEmail = nil
            signInError = error.localizedDescription
        }
    }

    private func finish() {
        settings.serverURL = serverURL.trimmingCharacters(in: .whitespaces)
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
