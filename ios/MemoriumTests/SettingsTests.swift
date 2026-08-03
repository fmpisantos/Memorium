import Foundation
import Security
import Testing

@testable import Memorium

/// `AppSettings` is the whole of the app's configuration, and every property
/// writes through to the device on assignment. These tests pin that down: a
/// setting that quietly reverted on the next launch would have to be found by
/// noticing it, which nobody does.
/// Serialised: every test here swaps values in the one shared
/// `UserDefaults.standard`, so running them at once makes them fight.
@Suite("Settings persist across launches", .serialized)
struct SettingsPersistenceTests {
    /// A fresh `AppSettings` is exactly what the next launch builds.
    private func relaunch() -> AppSettings { AppSettings() }

    @Test("Turning auto-translate off survives a relaunch")
    func autoTranslateStaysOff() {
        withCleanDefaults(Key.autoTranslate) {
            let settings = AppSettings()
            settings.autoTranslate = false

            #expect(relaunch().autoTranslate == false)
        }
    }

    @Test("Auto-translate is on until it is turned off")
    func autoTranslateDefaultsOn() {
        withCleanDefaults(Key.autoTranslate) {
            // Never set: `bool(forKey:)` would report false here, which is why
            // the default is read through `object(forKey:)` instead.
            #expect(relaunch().autoTranslate)

            let settings = AppSettings()
            settings.autoTranslate = false
            settings.autoTranslate = true
            #expect(relaunch().autoTranslate)
        }
    }

    @Test("The language pair survives a relaunch")
    func languagesPersist() {
        withCleanDefaults(Key.sourceLang, Key.targetLang) {
            let settings = AppSettings()
            settings.sourceLang = "pt-PT"
            settings.targetLang = "nb-NO"

            let relaunched = relaunch()
            #expect(relaunched.sourceLang == "pt-PT")
            #expect(relaunched.targetLang == "nb-NO")
        }
    }

    /// Regression, and the reason `CODE_SIGN_IDENTITY` is set in project.yml:
    /// an app built with signing disabled has no entitlements at all, so every
    /// Keychain write is refused with errSecMissingEntitlement (-34018). The
    /// Google refresh token lives in the Keychain, so the symptom of that is
    /// being asked to sign in again on every single launch, with nothing
    /// visibly wrong.
    @Test("This build is entitled to use the Keychain")
    func keychainIsUsable() {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.memorium.app",
            kSecAttrAccount as String: "entitlement-probe",
        ]
        SecItemDelete(item as CFDictionary)
        defer { SecItemDelete(item as CFDictionary) }

        var insert = item
        insert[kSecValueData as String] = Data("probe".utf8)
        #expect(SecItemAdd(insert as CFDictionary, nil) == errSecSuccess)
    }

    @Test("Nothing secret is kept in UserDefaults")
    func secretsStayOutOfDefaults() {
        // A plain plist on disk that lands in unencrypted backups.
        for key in ["apiToken", "idToken", "refreshToken"] {
            #expect(UserDefaults.standard.string(forKey: key) == nil)
        }
    }

    // MARK: -

    private enum Key {
        static let autoTranslate = "autoTranslate"
        static let sourceLang = "sourceLang"
        static let targetLang = "targetLang"
    }

    /// Runs `body` against unset defaults, then puts the test host's own
    /// values back. Tests share one `UserDefaults.standard`.
    private func withCleanDefaults(_ keys: String..., body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }
}
