import AuthenticationServices
import CryptoKit
import Foundation
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import Security
import UIKit

/// The outcome of a federated sign-in is deterministic before Firebase is
/// contacted, which keeps the anonymous-account migration rule unit-testable.
enum SignInLinkPolicy: Equatable {
    case link
    case signIn

    static func decide(isAnonymous: Bool) -> SignInLinkPolicy {
        isAnonymous ? .link : .signIn
    }
}

final class AuthManager {
    static let shared = AuthManager()

    private let errorLogger: ErrorLogger

    init(errorLogger: ErrorLogger = CrashlyticsErrorLogger.shared) {
        self.errorLogger = errorLogger
    }

    /// Starts the Apple OAuth flow and reports the resulting Firebase user.
    @MainActor
    func signInWithApple() async -> Result<User, Error> {
        do {
            let credential = try await appleCredential()
            let result = try await authenticate(credential)
            handleSuccessfulSignIn(result)
            return .success(result.user)
        } catch {
            errorLogger.log("Sign in with Apple failed")
            errorLogger.recordError(error)
            return .failure(error)
        }
    }

    /// Starts the Google OAuth flow and reports the resulting Firebase user.
    @MainActor
    func signInWithGoogle() async -> Result<User, Error> {
        do {
            let credential = try await googleCredential()
            let result = try await authenticate(credential)
            handleSuccessfulSignIn(result)
            return .success(result.user)
        } catch {
            // Google keeps its own Keychain session. Clear it when Firebase did not
            // complete so a retry cannot appear to sign in by itself.
            GIDSignIn.sharedInstance.signOut()
            errorLogger.log("Sign in with Google failed")
            errorLogger.recordError(error)
            return .failure(error)
        }
    }

    @MainActor
    private func googleCredential() async throws -> AuthCredential {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw GoogleSignInSetupError.missingClientID
        }

        guard let presentingViewController = Self.presentingViewController() else {
            throw GoogleSignInSetupError.missingPresentingViewController
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presentingViewController
        )
        guard let idToken = result.user.idToken?.tokenString else {
            throw GoogleSignInSetupError.missingIDToken
        }

        return GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
    }

    @MainActor
    private static func presentingViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return topViewController(from: root)
    }

    @MainActor
    private static func topViewController(from base: UIViewController?) -> UIViewController? {
        if let presented = base?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tabs = base as? UITabBarController {
            return topViewController(from: tabs.selectedViewController)
        }
        return base
    }

    @MainActor
    private func appleCredential() async throws -> AuthCredential {
        let rawNonce = try Self.randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)

        let appleCredential = try await Self.performAppleAuthorization(request)
        guard let identityToken = appleCredential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            throw AppleSignInError.missingIdentityToken
        }

        return OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleCredential.fullName
        )
    }

    @MainActor
    private static func performAppleAuthorization(
        _ request: ASAuthorizationAppleIDRequest
    ) async throws -> ASAuthorizationAppleIDCredential {
        let coordinator = AppleAuthorizationCoordinator()
        return try await withCheckedThrowingContinuation { continuation in
            // Keep the coordinator alive until the authorization controller responds.
            coordinator.start(request: request) { result in
                _ = coordinator
                continuation.resume(with: result)
            }
        }
    }

    private static func randomNonce(length: Int = 32) throws -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let limit = UInt8.max - (UInt8.max % UInt8(charset.count))
        var nonce = ""

        while nonce.count < length {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw AppleSignInError.nonceGenerationFailed }
            for byte in bytes where byte < limit {
                nonce.append(charset[Int(byte) % charset.count])
                if nonce.count == length { break }
            }
        }
        return nonce
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func authenticate(_ credential: AuthCredential) async throws -> AuthDataResult {
        let currentUser = Auth.auth().currentUser
        switch SignInLinkPolicy.decide(isAnonymous: currentUser?.isAnonymous == true) {
        case .signIn:
            return try await Auth.auth().signIn(with: credential)
        case .link:
            do {
                return try await currentUser!.link(with: credential)
            } catch {
                let authError = error as NSError
                guard AuthErrorCode(rawValue: authError.code) == .credentialAlreadyInUse else {
                    throw error
                }

                errorLogger.log("Anonymous credential already in use; signing in to existing account")
                errorLogger.recordError(error)

                // Firebase may return a refreshed credential in userInfo. If it
                // does not, the original provider credential is still valid for
                // the existing account and is the documented fallback.
                let updatedCredential = authError.userInfo[AuthErrors.userInfoUpdatedCredentialKey] as? AuthCredential
                return try await Auth.auth().signIn(with: updatedCredential ?? credential)
            }
        }
    }

    private func handleSuccessfulSignIn(_ result: AuthDataResult) {
        TelemetryManager.shared.identifyUser(userId: result.user.uid)
        if result.additionalUserInfo?.isNewUser == true {
            TelemetryManager.shared.trackUserSignedUp()
            Task { await NotificationService.shared.send(.welcome) }
        } else {
            TelemetryManager.shared.trackUserLoggedIn()
        }
        FirestoreSyncManager.shared.syncOnSignInCompleted()
    }

    static func isSignInCancellation(_ error: Error) -> Bool {
        if let authError = error as? AuthErrorCode,
           authError == .webContextCancelled {
            return true
        }

        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == ASAuthorizationError.canceled.rawValue {
            return true
        }
        return nsError.domain == kGIDSignInErrorDomain
            && nsError.code == -5 // kGIDSignInErrorCodeCanceled in GoogleSignIn 7.x
    }

    static func signInErrorMessage(for error: Error) -> String {
        let code = (error as? AuthErrorCode) ?? AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .networkError:
            return LocalizationHelper.localized("No connection — check your network and try again.")
        case .invalidCredential, .operationNotAllowed:
            return LocalizationHelper.localized("Sign-in isn't available right now. Please try again later.")
        default:
            return LocalizationHelper.localized("Sign-in isn't available right now. Please try again later.")
        }
    }

    func signOut() async {
        if GroupRideManager.shared.state.isActive {
            await GroupRideManager.shared.leaveGroup()
        }
        if LiveSharingManager.shared.isActive {
            await LiveSharingManager.shared.endSessionAwaitingAuth(reason: "Signed out")
        }
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    func deleteCloudData() async throws {
        try await FirestoreSyncManager.shared.deleteCloudData()
    }

    func deleteAccountAndData(feedback: String) async throws {
        TelemetryManager.shared.trackAccountDeletionRequested(reason: feedback)
        if GroupRideManager.shared.state.isActive {
            await GroupRideManager.shared.leaveGroup()
        }
        if LiveSharingManager.shared.isActive {
            await LiveSharingManager.shared.endSessionAwaitingAuth(reason: "Account deleted")
        }
        await NotificationService.shared.send(.deleteAccount)
        try await deleteCloudData()
        try await Auth.auth().currentUser?.delete()
        try await DataRepository.shared.wipeAllLocalData()
        await RideStatsStore.shared.reset()
        await signOut()
    }
}

private enum AppleSignInError: Error {
    case missingIdentityToken
    case nonceGenerationFailed
}

private enum GoogleSignInSetupError: Error {
    case missingClientID
    case missingPresentingViewController
    case missingIDToken
}

@MainActor
private final class AppleAuthorizationCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var completion: ((Result<ASAuthorizationAppleIDCredential, Error>) -> Void)?

    func start(
        request: ASAuthorizationAppleIDRequest,
        completion: @escaping (Result<ASAuthorizationAppleIDCredential, Error>) -> Void
    ) {
        self.completion = completion
        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(AppleSignInError.missingIdentityToken))
            return
        }
        finish(.success(credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else {
            preconditionFailure("Apple Sign-In requires an active window scene")
        }
        return scene.windows.first(where: \.isKeyWindow) ?? UIWindow(windowScene: scene)
    }

    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        let completion = completion
        self.completion = nil
        controller = nil
        completion?(result)
    }
}
