import Foundation
import GoogleSignIn
import Observation
import os
import UIKit

/// Signing in to Google, and handing the server a fresh identity token.
///
/// The app stores no shared secret. What lives on the device is a Google
/// refresh token, which the SDK keeps in the Keychain and trades for a new ID
/// token every hour; the server verifies that token's signature and checks the
/// address against its allowlist. Nothing to copy, paste or re-enter.
///
/// A singleton because it wraps one: `GIDSignIn.sharedInstance` is
/// process-wide, and pretending otherwise would just move the problem.
@Observable
@MainActor
final class AuthService {
    static let shared = AuthService()

    enum AuthError: LocalizedError {
        case notConfigured
        case signedOut
        case noPresenter
        case noIdentityToken

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "This build has no Google client ID. See GOOGLE_CLIENT_ID in ios/project.yml."
            case .signedOut:
                "You're signed out."
            case .noPresenter:
                "Couldn't find a window to present the Google sheet from."
            case .noIdentityToken:
                "Google signed you in but returned no identity token."
            }
        }
    }

    /// The signed-in address, and the thing the server checks its allowlist
    /// against. `nil` means signed out.
    private(set) var email: String?

    /// True until a previous session has been restored. The UI waits rather
    /// than flashing the sign-in screen at someone who is already signed in.
    private(set) var isRestoring = true

    /// `nil` when the build was made without a Google client ID, which is the
    /// state a fresh clone is in.
    let clientID: String?

    private let log = Logger(subsystem: "com.memorium.app", category: "auth")

    var isSignedIn: Bool { email != nil }
    var isConfigured: Bool { clientID != nil }

    private init() {
        // Set from GOOGLE_CLIENT_ID at build time; see project.yml.
        let value = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        clientID = value.isEmpty ? nil : value

        if let clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    /// Picks up where the last launch left off, without showing anything.
    func restore() async {
        defer { isRestoring = false }
        guard isConfigured, GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            email = user.profile?.email
        } catch {
            // Expired or revoked from the Google account page. Not an error to
            // show: it is simply a signed-out app.
            log.info("no previous Google session to restore: \(error.localizedDescription)")
            email = nil
        }
    }

    @discardableResult
    func signIn() async throws -> String {
        guard isConfigured else { throw AuthError.notConfigured }
        guard let presenter else { throw AuthError.noPresenter }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let address = result.user.profile?.email else {
            throw AuthError.noIdentityToken
        }
        email = address
        return address
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        email = nil
    }

    /// A currently-valid Google ID token, refreshed if it has aged out.
    ///
    /// Every request calls this. ID tokens last an hour, and the refresh is a
    /// local no-op until the last minutes of that, so this is cheap.
    func idToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            email = nil
            throw AuthError.signedOut
        }
        let refreshed = try await user.refreshTokensIfNeeded()
        guard let token = refreshed.idToken?.tokenString else {
            throw AuthError.noIdentityToken
        }
        email = refreshed.profile?.email ?? email
        return token
    }

    /// The OAuth callback coming back into the app.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    /// The topmost view controller, which is what Google's sheet attaches to.
    private var presenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window =
            scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.keyWindow
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
