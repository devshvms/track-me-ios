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
        try await deleteCloudData()
        try await Auth.auth().currentUser?.delete()
    }
}
