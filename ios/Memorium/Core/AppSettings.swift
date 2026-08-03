import Foundation
import Observation

@Observable
final class AppSettings {
    private enum Key {
        static let serverURL = "serverURL"
        static let sourceLang = "sourceLang"
        static let targetLang = "targetLang"
        static let onboarded = "onboarded"
        static let speakingMode = "speakingMode"
    }

    private let defaults = UserDefaults.standard

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL) }
    }

    /// Held in the Keychain, not UserDefaults.
    var apiToken: String {
        didSet { Keychain.set(apiToken, for: "apiToken") }
    }

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

    init() {
        serverURL = defaults.string(forKey: Key.serverURL) ?? "http://localhost:8000"
        apiToken = Keychain.get("apiToken") ?? ""
        sourceLang = defaults.string(forKey: Key.sourceLang) ?? "en-US"
        targetLang = defaults.string(forKey: Key.targetLang) ?? "es-ES"
        hasOnboarded = defaults.bool(forKey: Key.onboarded)
        speakingMode = defaults.bool(forKey: Key.speakingMode)

        #if DEBUG
            // Skip onboarding when launched with credentials in the
            // environment, so the simulator can be driven from a script:
            //   xcrun simctl launch booted com.memorium.app \
            //     --env MEMORIUM_DEV_URL=... --env MEMORIUM_DEV_TOKEN=...
            let env = ProcessInfo.processInfo.environment
            if let url = env["MEMORIUM_DEV_URL"], let token = env["MEMORIUM_DEV_TOKEN"] {
                serverURL = url
                apiToken = token
                hasOnboarded = true
                if let source = env["MEMORIUM_DEV_SOURCE"] { sourceLang = source }
                if let target = env["MEMORIUM_DEV_TARGET"] { targetLang = target }
            }
        #endif
    }

    var isConfigured: Bool {
        !apiToken.isEmpty && URL(string: serverURL) != nil
    }

    func makeClient() -> APIClient {
        APIClient(baseURL: URL(string: serverURL)!, token: apiToken)
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
}
