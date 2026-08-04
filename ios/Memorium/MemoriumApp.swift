import SwiftData
import SwiftUI

@main
struct MemoriumApp: App {
    @State private var settings = AppSettings()
    @State private var speech = SpeechService()
    @State private var auth = AuthService.shared

    /// The outbox has to survive a crash mid-session, so it is on disk rather
    /// than in memory.
    private let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: PendingGrade.self, CachedQueue.self, CachedPhrases.self
            )
        } catch {
            // The cache is disposable; losing it is better than refusing to
            // launch. Unsent grades would be lost, which is why this is a
            // last resort rather than the first thing tried.
            return try! ModelContainer(
                for: PendingGrade.self, CachedQueue.self, CachedPhrases.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(speech)
                .environment(auth)
                // Google's sheet comes back into the app through the URL
                // scheme built from GOOGLE_REVERSED_CLIENT_ID.
                .onOpenURL { auth.handle($0) }
                .task { await auth.restore() }
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AuthService.self) private var auth

    var body: some View {
        if auth.isRestoring {
            // Restoring the Google session takes a moment. Showing onboarding
            // in the meantime would flash the sign-in screen at someone who is
            // already signed in.
            ProgressView()
        } else if settings.hasOnboarded && settings.isConfigured && auth.isSignedIn {
            TabView {
                Tab("Study", systemImage: "brain.head.profile") {
                    StudyView()
                }
                Tab("Phrases", systemImage: "text.bubble") {
                    PracticeView()
                }
                Tab("Deck", systemImage: "text.book.closed") {
                    DeckView()
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView()
                }
            }
        } else {
            OnboardingView()
        }
    }
}
