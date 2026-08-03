import GoogleSignInSwift
import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AuthService.self) private var auth

    @State private var sourceLang = "en-US"
    @State private var targetLang = "es-ES"
    @State private var isSigningIn = false
    @State private var signInError: String?
    /// The address the server confirmed it will accept.
    @State private var acceptedEmail: String?

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
                sourceLang = settings.sourceLang
                targetLang = settings.targetLang
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if !settings.isConfigured {
                Label(
                    "This build has no server address. Set MEMORIUM_API_URL in ios/project.yml, then run xcodegen generate.",
                    systemImage: "wrench.and.screwdriver"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if !auth.isConfigured {
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
                    .disabled(isSigningIn)

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
                "Your server only answers to the addresses in its MEMORIUM_ALLOWED_EMAILS list. Nothing to copy or paste — signing in is the whole of it."
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

        do {
            acceptedEmail = try await settings.makeClient().me()
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
