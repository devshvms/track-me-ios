import Foundation

/// Retired emergency-flow compatibility state.
///
/// Android keeps this reader because an install can be upgraded while a ride is being
/// finalized. iOS follows the same rule: old suppression bits are consumed safely, but no new
/// SOS or SMS state can be created because the trigger surface was retired.
final class EmergencyManager {
    static let shared = EmergencyManager()

    private static let emergencyTriggeredForRideKey = "emergency_triggered_for_ride"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated deinit {}

    /// Always false after the emergency trigger was retired. Kept for the calm-moment gate so
    /// older call sites do not accidentally treat a removed flow as active.
    var isEmergencyActive: Bool { false }

    /// Start a fresh per-ride suppression window. A retired SOS cannot set the bit, but retaining
    /// this lifecycle hook keeps upgraded rides and Android parity deterministic.
    func beginRideSession() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(false, forKey: Self.emergencyTriggeredForRideKey)
    }

    /// Consume any legacy per-ride suppression bit exactly once at finalization.
    @discardableResult
    func consumeRideSuppression() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasTriggered = defaults.bool(forKey: Self.emergencyTriggeredForRideKey)
        defaults.removeObject(forKey: Self.emergencyTriggeredForRideKey)
        return wasTriggered
    }

    /// Removes the only persisted iOS emergency-flow bit that predates retirement.
    func clearLegacyState() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.emergencyTriggeredForRideKey)
    }
}
