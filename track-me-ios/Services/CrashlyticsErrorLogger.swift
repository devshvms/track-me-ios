import FirebaseCrashlytics

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
        Crashlytics.crashlytics().record(error: error)
    }

    func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }
}
