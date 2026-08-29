import Foundation

/// TASK-230: the two durations a finished ride has, and the rule for each.
///
/// Mid-ride the HUD shows moving time and total side by side, so the rider is taught the
/// distinction exists. When the ride ended, one vanished and the survivor was labelled only
/// "Duration" — a rider who paused for twenty minutes could not tell which of the two they were
/// holding. Both are shown now, and both come from here so Ride Detail, History and any future
/// surface cannot drift apart on the arithmetic.
enum RideDurations {

    /// Pause-excluded, and the single definition of a ride's *duration* per
    /// `HISTORY_DETAIL_REDESIGN_SPEC` §5.1 — the figure that must stay consistent with distance
    /// and average speed.
    static func movingSeconds(for ride: Ride) -> Double {
        Double(ride.aggregateSnapshot.movingDurationMillis) / 1_000
    }

    /// Wall-clock elapsed, the pair to ``movingSeconds(for:)``.
    ///
    /// Unlike moving time this needs no reconciliation — it is two stored timestamps — so a ride
    /// whose aggregates were never rebuilt still shows one real number. Nil only when the ride has
    /// no usable end, which is not a finished ride; §5.1 keeps wall time from ever being labelled
    /// simply "Duration".
    static func totalElapsedSeconds(for ride: Ride) -> Double? {
        guard let endTime = ride.endTime, endTime > ride.startTime else { return nil }
        return endTime.timeIntervalSince(ride.startTime)
    }
}
