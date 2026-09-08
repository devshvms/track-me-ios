import Foundation

/// SCOPE_1.8.7 §6.1.4 scenario 22 — *"Your ride ended, but you are still in a live group."*
///
/// The trust sibling of §6.1.1 #6. A group ride keeps sharing the rider's position with the other
/// members for as long as the group is live, and stopping a ride does not leave the group. So a
/// rider who finishes, pockets the phone and goes to dinner can remain visible to people who are no
/// longer riding with them, having done nothing to cause it and seen nothing to say so.
///
/// ### Class A, and why that is not a licence
///
/// This is consequential — it is about location sharing the rider is not aware of — so §6.0's
/// proactive budget does not apply. That makes the dedupe rules the only thing standing between a
/// trust notification and a nuisance, so they are strict: **once per group, ever**. A rider who has
/// been told they are still in group X and chose to stay has answered the question. Asking again
/// after their next ride is the app arguing with a decision it already prompted.
///
/// ### Why it does not leave the group for them
///
/// The same reason scenario 4 does not stop the ride. Staying in the group after your own ride ends
/// is a completely ordinary thing to do — the ride leader who finishes first, anyone waiting for the
/// back marker — and silently ending someone's group participation would break a social contract the
/// app cannot see. It tells, and offers one tap to leave.
///
/// The Android twin is `GroupPresenceNotice.kt`.
enum GroupPresenceNotice {

    /// Whether to tell the rider they are still in a live group.
    ///
    /// - Parameters:
    ///   - isGroupLive: whether that group is still broadcasting. An expired or ended group shares
    ///     nothing, so saying so would raise an alarm about a risk that has already passed.
    ///   - isRideActive: whether a ride is running. During a ride, group presence is the point and
    ///     the live activity already states it — this is only about the gap afterwards.
    static func shouldNotify(
        activeGroupId: String?,
        isGroupLive: Bool,
        isRideActive: Bool,
        alreadyNoticedGroupIds: Set<String>
    ) -> Bool {
        guard let groupId = activeGroupId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupId.isEmpty
        else { return false }
        guard isGroupLive else { return false }
        guard !isRideActive else { return false }
        guard !alreadyNoticedGroupIds.contains(groupId) else { return false }
        return true
    }
}
