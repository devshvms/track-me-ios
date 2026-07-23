import Foundation
import FirebaseAuth

class AuthManager {
    static let shared = AuthManager()

    // Native Apple Sign-In via Firebase OAuthProvider
    func signInWithApple() {
        let provider = OAuthProvider(providerID: "apple.com")
        provider.scopes = ["email", "name"]

        provider.getCredentialWith(nil) { credential, error in
            if let error = error {
                print("Apple sign in error: \(error.localizedDescription)")
                return
            }
            if let credential = credential {
                Auth.auth().signIn(with: credential) { authResult, error in
                    if let error = error {
                        print("Firebase Auth error: \(error.localizedDescription)")
                    } else if let result = authResult {
                        TelemetryManager.shared.identifyUser(userId: result.user.uid)
                        if result.additionalUserInfo?.isNewUser == true {
                            TelemetryManager.shared.trackUserSignedUp()
                            // D3: welcome email after the first successful sign-up.
                            // Fire-and-forget — a missed email must not block sign-in.
                            Task { await NotificationService.shared.send(.welcome) }
                        } else {
                            TelemetryManager.shared.trackUserLoggedIn()
                        }
                    }
                }
            }
        }
    }

    // Generic Google Sign-In via Firebase OAuthProvider
    // Using this method avoids adding the heavy GoogleSignIn SDK directly
    func signInWithGoogle() {
        let provider = OAuthProvider(providerID: "google.com")
        provider.scopes = ["email", "profile"]

        provider.getCredentialWith(nil) { credential, error in
            if let error = error {
                print("Google sign in error: \(error.localizedDescription)")
                return
            }
            if let credential = credential {
                Auth.auth().signIn(with: credential) { authResult, error in
                    if let error = error {
                        print("Firebase Auth error: \(error.localizedDescription)")
                    } else if let result = authResult {
                        TelemetryManager.shared.identifyUser(userId: result.user.uid)
                        if result.additionalUserInfo?.isNewUser == true {
                            TelemetryManager.shared.trackUserSignedUp()
                            // D3: welcome email after the first successful sign-up.
                            // Fire-and-forget — a missed email must not block sign-in.
                            Task { await NotificationService.shared.send(.welcome) }
                        } else {
                            TelemetryManager.shared.trackUserLoggedIn()
                        }
                    }
                }
            }
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
    }

    func deleteCloudData() async throws {
        try await FirestoreSyncManager.shared.deleteCloudData()
    }

    func deleteAccountAndData(feedback: String) async throws {
        TelemetryManager.shared.trackAccountDeletionRequested(reason: feedback)
        // D3: send the delete_account email while the token is still valid — it is
        // revoked once the account is deleted. Best-effort; never blocks deletion.
        await NotificationService.shared.send(.deleteAccount)

        // Cloud first: if the purge fails, stop here so it's visible and retryable and the
        // auth record still exists.
        try await deleteCloudData()

        // Delete the auth user. This can throw requiresRecentLogin.
        try await Auth.auth().currentUser?.delete()

        // Only reached if BOTH cloud delete and auth delete succeeded → wipe local + sign out.
        try await DataRepository.shared.wipeAllLocalData()
        await RideStatsStore.shared.reset()
        signOut()
    }
}
