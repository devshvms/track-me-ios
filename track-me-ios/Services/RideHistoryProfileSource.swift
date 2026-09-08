import Foundation
import SwiftData

/// SCOPE_1.8.7 §6.1.3 #12a / §6.1.2 #10b — the boundary where timestamps become weekdays.
///
/// ``RideHistoryProfile`` deliberately takes a weekday and an hour rather than a timestamp, because
/// a policy that reaches for the device clock cannot be tested at the boundaries that matter. This
/// is the other side of that decision: the one place that owns a `Calendar`, and therefore the one
/// place a timezone bug can live.
///
/// ### The weekday numbering is the trap
///
/// `Calendar.component(.weekday,…)` returns **1 for Sunday** and 2 for Monday. The vectors are
/// ISO-8601, where Monday is 1 and Sunday is 7. Passing the raw weekday through shifts every
/// suggestion by a day and shows a Saturday rider "Friday" — a wrong answer that looks like a
/// plausible one, which is the worst kind. `java.util.Calendar` numbers weekdays identically, so
/// Android has the same conversion and the same trap.
///
/// The Android twin is `RideHistoryProfileSource.kt`.
enum RideHistoryProfileSource {

    /// A rider's routine two years ago is not their routine, and an unbounded fetch on the main
    /// history store for a settings screen is a jank source.
    static let defaultLimit = 60

    /// Reads recent history and converts it into policy samples.
    ///
    /// Rides are bucketed in the device's **current** timezone rather than the one they were
    /// recorded in — `startZoneId` is deliberately ignored here. That is the right choice for a
    /// suggestion: someone who has moved wants a reminder in the mornings they are now living, not
    /// the mornings they used to.
    @MainActor
    static func samples(
        context: ModelContext,
        calendar: Calendar = .current,
        limit: Int = defaultLimit
    ) -> [RideHistoryProfile.Sample] {
        // `qualifiesForStats` reuses the bar the rest of the app already applies to "is this a real
        // activity" — a 40-second accidental start should not get a vote on when someone usually
        // rides. `isSample` keeps the first-run fixture out: suggesting a slot derived from demo
        // data would be the app inventing a routine and attributing it to the user, which is the
        // exact failure scenario 12 was cut for.
        var descriptor = FetchDescriptor<Ride>(
            predicate: #Predicate { ride in
                ride.qualifiesForStats && !ride.isSample && !ride.pendingDelete
            },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let rides = try? context.fetch(descriptor) else { return [] }
        return rides.map { sample(from: $0, calendar: calendar) }
    }

    static func sample(from ride: Ride, calendar: Calendar) -> RideHistoryProfile.Sample {
        let components = calendar.dateComponents([.weekday, .hour], from: ride.startTime)
        return RideHistoryProfile.Sample(
            dayOfWeek: isoDayOfWeek(components.weekday ?? 1),
            hour: components.hour ?? 0,
            activeMinutes: (ride.movingDurationMillis ?? 0) / 60_000,
            persona: ride.persona
        )
    }

    /// SCOPE_1.8.7 §6.1.2 #10b — the start-button line, or nil when there is nothing true to say.
    ///
    /// Kept here rather than in the view so the two reads it needs — the rider's history and their
    /// earned progress — come from one place and apply the same filters.
    ///
    /// The gamification pair, not the dashboard pair: levels count `RideSource.recorded` only, so
    /// including imported rides would promise a level this ride cannot actually reach.
    @MainActor
    static func startButtonProximityLine(
        context: ModelContext,
        persona: RidePersona,
        calendar: Calendar = .current
    ) -> StartButtonProximity.Line? {
        var descriptor = FetchDescriptor<Ride>(
            predicate: #Predicate { ride in
                ride.qualifiesForStats && !ride.isSample && !ride.pendingDelete
            },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = defaultLimit
        guard let rides = try? context.fetch(descriptor) else { return nil }

        let earned = rides.filter { RideSource.earnsProgress($0.source) }
        let snapshot = GamificationEngine.deriveSnapshot(
            facts: GamificationFacts(
                lifetimeActivityCount: earned.count,
                lifetimeActiveDurationMillis: earned.reduce(Int64(0)) { $0 + ($1.movingDurationMillis ?? 0) }
            )
        )

        return StartButtonProximity.line(
            minutesToNextLevel: snapshot.nextThresholdMinutes.map { $0 - snapshot.currentMinutes },
            nextLevelName: snapshot.nextLevelNameKey,
            typicalActiveMinutes: RideHistoryProfile.typicalActiveMinutes(
                rides.map { sample(from: $0, calendar: calendar) },
                persona: persona.rawValue
            )
        )
    }

    /// Foundation's Sunday-first weekday to ISO-8601's Monday-first.
    static func isoDayOfWeek(_ foundationWeekday: Int) -> Int {
        foundationWeekday == 1 ? 7 : foundationWeekday - 1
    }

    /// The inverse, for scheduling against `DateComponents` from a stored ISO weekday.
    static func foundationWeekday(_ isoDayOfWeek: Int) -> Int {
        isoDayOfWeek == 7 ? 1 : isoDayOfWeek + 1
    }
}
