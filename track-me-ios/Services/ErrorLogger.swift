import Foundation

/// Modular error-reporting interface shared conceptually with Android's
/// `in.shvms.trackme.utils.logger.ErrorLogger`.
protocol ErrorLogger: AnyObject, Sendable {
    /// Enables the underlying crash/error collection service.
    func initialize()

    /// Associates future reports with the signed-in account. Pass `nil` on sign-out.
    func setUserId(_ userId: String?)

    /// Attaches a searchable key/value pair to future reports.
    func setCustomKey(_ key: String, value: String)

    /// Records a non-fatal error with its stack/context.
    func recordError(_ error: Error)

    /// Adds a human-readable breadcrumb to future reports.
    func log(_ message: String)
}
