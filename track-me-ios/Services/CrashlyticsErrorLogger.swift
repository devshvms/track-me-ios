import Foundation
import FirebaseCrashlytics
import FirebaseFirestore

/// Firebase-backed implementation of the app-wide error logger.
final class CrashlyticsErrorLogger: ErrorLogger, @unchecked Sendable {
    static let shared = CrashlyticsErrorLogger()

    private init() {}

    func initialize() {
        // TASK-250: collection follows the same environment gate as analytics. A debug or Simulator
        // crash is one someone is already looking at in a debugger; sending it makes the production
        // crash-free-users rate a number about developers rather than riders, and a deliberately
        // crashed test run can bury a real regression under its own noise.
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(TelemetryEnvironment.allowsDelivery)
    }

    func setUserId(_ userId: String?) {
        Crashlytics.crashlytics().setUserID(userId ?? "")
    }

    func setCustomKey(_ key: String, value: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    func recordError(_ error: Error) {
        guard Self.isReportable(error) else { return }
        Crashlytics.crashlytics().record(error: error)
    }

    func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    /// TASK-333: parity with Android's `isReportable(Throwable)` — drop structured-concurrency
    /// cancellation and expected transient/auth-boundary Firestore rejections.
    static func isReportable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return false
        }
        if nsError.domain == FirestoreErrorDomain {
            switch nsError.code {
            case FirestoreErrorCode.permissionDenied.rawValue,
                 FirestoreErrorCode.unauthenticated.rawValue,
                 FirestoreErrorCode.unavailable.rawValue,
                 FirestoreErrorCode.deadlineExceeded.rawValue,
                 FirestoreErrorCode.cancelled.rawValue:
                return false
            default:
                return true
            }
        }
        return true
    }
}
