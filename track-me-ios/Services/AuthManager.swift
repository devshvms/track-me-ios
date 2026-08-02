import AuthenticationServices
import Foundation
import FirebaseAuth

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
        await signIn(providerID: "apple.com", scopes: ["email", "name"])
    }

    /// Starts the Google OAuth flow and reports the resulting Firebase user.
    @MainActor
    func signInWithGoogle() async -> Result<User, Error> {
        await signIn(providerID: "google.com", scopes: ["email", "profile"])
    }

    @MainActor
    private func signIn(providerID: String, scopes: [String]) async -> Result<User, Error> {
        do {
            let provider = OAuthProvider(providerID: providerID)
            provider.scopes = scopes
            let credential = try await credential(for: provider)
            let result = try await authenticate(credential)
            handleSuccessfulSignIn(result)
            return .success(result.user)
        } catch {
            errorLogger.log("Federated sign-in failed")
            errorLogger.recordError(error)
            return .failure(error)
        }
    }

    private func credential(for provider: OAuthProvider) async throws -> AuthCredential {
        try await withCheckedThrowingContinuation { continuation in
            provider.getCredentialWith(nil) { credential, error in
                if let credential {
                    continuation.resume(returning: credential)
                } else {
                    continuation.resume(throwing: error ?? AuthErrorCode.invalidCredential)
                }
            }
        }
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
        return nsError.domain == "com.apple.AuthenticationServices.AuthorizationError"
            && nsError.code == ASAuthorizationError.canceled.rawValue
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
        if LiveSharingManager.shared.isActive {
            await LiveSharingManager.shared.endSessionAwaitingAuth(reason: "Signed out")
        }
        try? Auth.auth().signOut()
        Task { @MainActor in
            DataRepository.shared.disableEmergencySetup()
        }
    }

    func deleteCloudData() async throws {
        try await FirestoreSyncManager.shared.deleteCloudData()
    }

    func deleteAccountAndData(feedback: String) async throws {
        TelemetryManager.shared.trackAccountDeletionRequested(reason: feedback)
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
