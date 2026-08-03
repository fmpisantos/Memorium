import SwiftData
import SwiftUI

@main
struct MemoriumApp: App {
    @State private var settings = AppSettings()
    @State private var speech = SpeechService()

    /// The outbox has to survive a crash mid-session, so it is on disk rather
    /// than in memory.
    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: PendingGrade.self, CachedQueue.self)
        } catch {
            // The cache is disposable; losing it is better than refusing to
            // launch. Unsent grades would be lost, which is why this is a
            // last resort rather than the first thing tried.
            return try! ModelContainer(
                for: PendingGrade.self, CachedQueue.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(speech)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.hasOnboarded && settings.isConfigured {
            TabView {
                Tab("Study", systemImage: "brain.head.profile") {
                    StudyView()
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
