import Foundation
import FirebaseAuth

/// D3 — transactional email trigger (iOS). Fire-and-forget.
///
/// The client passes ONLY a `type` enum; the Vercel backend owns the subject +
/// brand HTML and derives the recipient from the verified Firebase token
/// (self-only send). A missed transactional email must never block sign-up or
/// account deletion, so failures are logged and swallowed by callers.
enum TransactionalEmailType: String {
    case welcome
    case deleteAccount = "delete_account"
}

struct NotificationService {
    static let shared = NotificationService()

    private let errorLogger: ErrorLogger

    init(errorLogger: ErrorLogger = CrashlyticsErrorLogger.shared) {
        self.errorLogger = errorLogger
    }

    private var endpoint: URL? {
        URL(string: "\(APIConfig.baseURL)/api/notify/send")
    }

    /// POST the notify request. Must be called while the user is still
    /// authenticated. For `.deleteAccount`, fire this BEFORE deleting the
    /// account — the ID token is revoked afterwards.
    @discardableResult
    func send(_ type: TransactionalEmailType) async -> Bool {
        guard let endpoint else { return false }
        guard let user = Auth.auth().currentUser else { return false }

        do {
            let token = try await user.getIDToken()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["type": type.rawValue])

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Never log the recipient — the server already redacts.
                errorLogger.log("NotificationService \(type.rawValue) failed (non-2xx)")
                return false
            }
            return true
        } catch {
            errorLogger.log("NotificationService \(type.rawValue) failed")
            errorLogger.recordError(error)
            return false
        }
    }
}
