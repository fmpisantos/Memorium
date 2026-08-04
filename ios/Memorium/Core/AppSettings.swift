import Foundation
import Observation

@Observable
final class AppSettings {
    private enum Key {
        static let sourceLang = "sourceLang"
        static let targetLang = "targetLang"
        static let onboarded = "onboarded"
        static let speakingMode = "speakingMode"
        static let autoTranslate = "autoTranslate"
        static let practiceMode = "practiceMode"
    }

    private let defaults = UserDefaults.standard

    /// The server this build talks to, baked in at build time from
    /// MEMORIUM_API_URL -- see project.yml. There is one server, so its address
    /// is a property of the build rather than something to type into every
    /// fresh install and then test by hand.
    let serverURL: String

    var sourceLang: String {
        didSet { defaults.set(sourceLang, forKey: Key.sourceLang) }
    }

    var targetLang: String {
        didSet { defaults.set(targetLang, forKey: Key.targetLang) }
    }

    var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.onboarded) }
    }

    /// When on, cards are answered by speaking rather than tapping.
    var speakingMode: Bool {
        didSet { defaults.set(speakingMode, forKey: Key.speakingMode) }
    }

    /// When on, adding a word fills in whichever side was left blank.
    var autoTranslate: Bool {
        didSet { defaults.set(autoTranslate, forKey: Key.autoTranslate) }
    }

    /// Which way round phrase practice was left. Remembered because it is a
    /// choice about what you are working on this week, not a per-session one.
    var practiceMode: PracticeMode {
        didSet { defaults.set(practiceMode.rawValue, forKey: Key.practiceMode) }
    }

    init() {
        var address = (Bundle.main.object(forInfoDictionaryKey: "MemoriumAPIURL") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        sourceLang = defaults.string(forKey: Key.sourceLang) ?? "en-US"
        targetLang = defaults.string(forKey: Key.targetLang) ?? "es-ES"
        hasOnboarded = defaults.bool(forKey: Key.onboarded)
        speakingMode = defaults.bool(forKey: Key.speakingMode)
        // On by default -- typing both halves of every word is the friction
        // that stops a deck growing. `object(forKey:)` rather than `bool`, so
        // that having turned it off survives a relaunch.
        autoTranslate = defaults.object(forKey: Key.autoTranslate) as? Bool ?? true
        // Dictation to begin with: hearing a whole sentence and writing it
        // down is the exercise the cards do least of.
        practiceMode =
            (defaults.string(forKey: Key.practiceMode).flatMap(PracticeMode.init(rawValue:)))
            ?? .dictation

        #if DEBUG
            // Point a debug build at a server on the desk without rebuilding,
            // so the simulator can be driven from a script:
            //   xcrun simctl launch booted com.memorium.app \
            //     --env MEMORIUM_DEV_URL=...
            // Signing in with Google still has to happen by hand -- that is
            // rather the point of it.
            let env = ProcessInfo.processInfo.environment
            if let url = env["MEMORIUM_DEV_URL"] {
                address = url
                hasOnboarded = true
                if let source = env["MEMORIUM_DEV_SOURCE"] { sourceLang = source }
                if let target = env["MEMORIUM_DEV_TARGET"] { targetLang = target }
            }
        #endif

        serverURL = address
    }

    /// A usable server address. False only for a build made without
    /// MEMORIUM_API_URL. Being *allowed* to use the server is a separate
    /// question, and `AuthService` answers that one.
    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: serverURL)?.scheme != nil
    }

    func makeClient() -> APIClient {
        guard let url = URL(string: serverURL), url.scheme != nil else {
            // Reported as "no server configured" rather than as a failure to
            // reach one, which is a different thing to go and fix.
            return APIClient(baseURL: URL(string: "http://unset.invalid")!) {
                throw APIError.notConfigured
            }
        }
        // The identity is fetched per request, so a token that expires
        // mid-session is refreshed rather than surfacing as a logout.
        return APIClient(baseURL: url) { try await AuthService.shared.idToken() }
    }
}

/// The language pairs offered at onboarding. The pair is a setting, not a
/// build constant: it drives the TTS voice, the speech-recognition locale, the
/// OCR languages, and which way round every card is asked.
struct LanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [LanguageOption] = [
        .init(code: "en-US", name: "English (US)"),
        .init(code: "en-GB", name: "English (UK)"),
        .init(code: "pt-PT", name: "Portuguese (Portugal)"),
        .init(code: "pt-BR", name: "Portuguese (Brazil)"),
        .init(code: "es-ES", name: "Spanish (Spain)"),
        .init(code: "es-MX", name: "Spanish (Mexico)"),
        .init(code: "fr-FR", name: "French"),
        .init(code: "de-DE", name: "German"),
        .init(code: "it-IT", name: "Italian"),
        .init(code: "nl-NL", name: "Dutch"),
        // Bokmål: the written standard used by most Norwegians, the one
        // Duolingo teaches, and the only one iOS ships a voice for.
        .init(code: "nb-NO", name: "Norwegian (Bokmål)"),
        .init(code: "sv-SE", name: "Swedish"),
        .init(code: "da-DK", name: "Danish"),
        .init(code: "fi-FI", name: "Finnish"),
        .init(code: "pl-PL", name: "Polish"),
        .init(code: "tr-TR", name: "Turkish"),
        .init(code: "ru-RU", name: "Russian"),
        .init(code: "ja-JP", name: "Japanese"),
        .init(code: "ko-KR", name: "Korean"),
        .init(code: "zh-CN", name: "Chinese (Simplified)"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// The language without its region, for wording a sentence around: "Read
    /// the Norwegian" rather than "Read the Norwegian (Bokmål)".
    static func shortName(for code: String) -> String {
        name(for: code).components(separatedBy: " (").first ?? code
    }
}
