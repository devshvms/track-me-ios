import FirebaseCrashlytics

/// Firebase-backed implementation of the app-wide error logger.
final class CrashlyticsErrorLogger: ErrorLogger, @unchecked Sendable {
    static let shared = CrashlyticsErrorLogger()

    private init() {}

    func initialize() {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
    }

    func setUserId(_ userId: String?) {
        Crashlytics.crashlytics().setUserID(userId ?? "")
    }

    func setCustomKey(_ key: String, value: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    func recordError(_ error: Error) {
        Crashlytics.crashlytics().record(error: error)
    }

    func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }
}
