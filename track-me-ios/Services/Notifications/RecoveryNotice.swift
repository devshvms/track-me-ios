import Foundation

/// SCOPE_1.8.7 §6.1.1 scenario 1 — whether, and how, to tell someone their ride was saved for them.
///
/// The iOS twin of `domain/notifications/RecoveryNotice.kt`.
///
/// The PRD lists this as a **currently failing** acceptance criterion: today an interrupted ride is
/// recovered in silence. Someone whose phone died mid-ride opens the app expecting to have lost it,
/// and either finds it by accident or never looks. §6.0 ranks it the highest-value item in the
/// release for that reason — it is not engagement, it is the app saying it did not lose your data.
///
/// Pure, so the decision and the shape of the message are testable without a device.
enum RecoveryNotice: Equatable {
    /// A single recovered ride, with its facts when they are available.
    case one(endedAtLabel: String?, distanceLabel: String?)
    /// Several at once — after a crash loop, or a long spell without opening the app.
    case many(count: Int)

    /// What to say, or nil when nothing should be said.
    ///
    /// - Parameters:
    ///   - endedAtLabel: already formatted by the caller in the user's locale and clock preference.
    ///     The decision must not format times itself — the same rule as `ReplayOverlay`, for the
    ///     same reason.
    ///   - distanceLabel: already formatted with the user's units.
    static func decide(
        recoveredCount: Int,
        discardedCount: Int,
        endedAtLabel: String?,
        distanceLabel: String?
    ) -> RecoveryNotice? {
        // A discarded ride had no GPS points at all: nothing was recorded, so nothing was lost and
        // there is nothing to tell anyone. Announcing cleanup would be the app narrating its own
        // housekeeping — and worse, it would read as "we deleted something of yours".
        guard recoveredCount > 0 else { return nil }

        // More than one is rare enough that naming a single end time would be misleading, and
        // listing several is a notification nobody reads. The count is the honest fact.
        if recoveredCount > 1 { return .many(count: recoveredCount) }

        // Both labels or neither. A half-formed sentence — "Recording stopped at ." — is worse than
        // the plain version, and the caller can legitimately produce neither when a recovered ride
        // has one point and no measurable distance.
        let endedAt = endedAtLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let distance = distanceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endedAt, !endedAt.isEmpty, let distance, !distance.isEmpty else {
            return .one(endedAtLabel: nil, distanceLabel: nil)
        }
        return .one(endedAtLabel: endedAt, distanceLabel: distance)
    }
}
