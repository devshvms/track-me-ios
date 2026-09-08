import Foundation

/// SCOPE_1.8.7 §6.1.2 scenario 10b — *"This one takes you past Explorer."*
///
/// Scenario 10 was cut and 10a was folded into the weekly recap. 10b is the third form of the same
/// fact, and the only one that is a prediction rather than a report: the rider has chosen a persona
/// and is about to press start, and the app can say that this ride is likely to cross a threshold.
///
/// ### Why this one is allowed to exist when #10 was cut
///
/// #10 failed §4.2 N2 because a scheduled nudge toward a threshold implies one action — go exert
/// yourself now, because the app is counting. 10b implies no action at all. The decision to ride is
/// already made; the app is not asking for it, it is answering a question the rider did not have to
/// ask. That is why it is **in-app only and never a notification**: the moment this sentence can
/// reach someone who has not opened the app, it becomes #10 again.
///
/// ### Why it is bounded by the rider's own typical ride
///
/// "This one takes you past Explorer" is a claim about *this* ride, so it has to be false when it
/// would be false. Comparing against the rider's median active minutes means the line appears for
/// someone 20 minutes short who typically rides 40, and stays quiet for someone 20 minutes short
/// who typically rides 10 — where the honest sentence would be "this one does not, quite".
///
/// The Android twin is `StartButtonProximity.kt`; both are proved against
/// `ride-history-profile-v1.json`.
enum StartButtonProximity {

    struct Line: Equatable {
        let minutes: Int64
        let levelName: String
    }

    /// The line to show under the start button, or nil when there is nothing true to say.
    ///
    /// - Parameters:
    ///   - minutesToNextLevel: remaining lifetime active minutes, or nil at the maximum level.
    ///   - typicalActiveMinutes: the rider's median active minutes, from ``RideHistoryProfile``.
    ///     Nil when there is no history — a first-time rider gets no prediction, because the app has
    ///     nothing to base one on and inventing a default would be the app guessing about a
    ///     stranger and then telling them what it guessed.
    static func line(
        minutesToNextLevel: Int64?,
        nextLevelName: String?,
        typicalActiveMinutes: Int64?
    ) -> Line? {
        guard let minutesToNextLevel,
              let nextLevelName, !nextLevelName.isEmpty,
              let typicalActiveMinutes, typicalActiveMinutes > 0
        else { return nil }
        // Already there. The reveal at ride save covers this, and "0 minutes away" is the app
        // failing to notice something the rider has already done.
        guard minutesToNextLevel > 0 else { return nil }
        // The prediction has to be true to be worth making.
        guard minutesToNextLevel <= typicalActiveMinutes else { return nil }
        return Line(minutes: minutesToNextLevel, levelName: nextLevelName)
    }
}
