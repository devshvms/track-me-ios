import Foundation

/// Platform-neutral contract for a just-saved "good ride" — the single input to the shared
/// A1 retention/telemetry hook. Mirrors Android's `GoodRideSummary`. Use the authoritative
/// in-memory distance/duration; never recompute from points here.
nonisolated struct GoodRideSummary {
    let rideId: String
    /// Epoch millis the ride was finalized.
    let finishedAtMillis: Int64
    /// Active (non-paused) ride duration in millis.
    let durationMillis: Int64
    /// Filtered ride distance in meters.
    let distanceMeters: Double
    /// Local first-run samples are replayable/exportable but never enter retention aggregates.
    let isSample: Bool
    /// Legacy compatibility flag for a ride that entered the retired emergency flow. The ride
    /// still contributes to history aggregates, but old downstream callers may suppress a reveal.
    /// Parity with Android `GoodRideSummary.suppressPostRideCelebrations`.
    let suppressPostRideCelebrations: Bool

    /// Explicit memberwise init so the new flag defaults to `false` while `let` immutability is
    /// preserved (Swift omits defaulted `let` properties from the synthesized init entirely).
    init(
        rideId: String,
        finishedAtMillis: Int64,
        durationMillis: Int64,
        distanceMeters: Double,
        isSample: Bool = false,
        suppressPostRideCelebrations: Bool = false
    ) {
        self.rideId = rideId
        self.finishedAtMillis = finishedAtMillis
        self.durationMillis = durationMillis
        self.distanceMeters = distanceMeters
        self.isSample = isSample
        self.suppressPostRideCelebrations = suppressPostRideCelebrations
    }
}

/// Versioned local aggregate of ride history, shared by all v1.6.0 retention features.
/// Codable so it persists as ONE versioned blob. Purely additive: new fields must be
/// optional-with-default in the decoder so an old blob still decodes (see custom `init(from:)`).
/// Weeks are Monday-anchored; each week is stored as the epoch-day of its Monday so
/// consecutive weeks differ by exactly 7 (parity with Android).
nonisolated struct RideStats: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maxProcessedIds = 200

    var schemaVersion: Int = RideStats.currentSchemaVersion
    var totalRides: Int = 0
    var totalDistanceMeters: Double = 0.0
    var longestDistanceMeters: Double = 0.0
    var longestDurationMillis: Int64 = 0
    var lastRideFinishedAtMillis: Int64 = 0
    var currentWeekStartEpochDay: Int = 0
    var currentWeekRideCount: Int = 0
    var currentWeekDistanceMeters: Double = 0.0
    var streakWeeks: Int = 0
    var lastStreakWeekStartEpochDay: Int = 0
    /// B3 streak forgiveness: whether a single-week miss can currently be auto-frozen. Consumed
    /// by a forgiven miss, refilled after any active week. `true` for a fresh store.
    var freezeAvailable: Bool = true
    /// B2 dedupe: Monday epoch-day of the completed week whose recap was already surfaced.
    var lastRecapShownWeekStartEpochDay: Int = 0
    var processedRideIds: [String] = []

    init() {}

    // Additive-safe decode: every field defaults if absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? RideStats.currentSchemaVersion
        totalRides = (try? c.decode(Int.self, forKey: .totalRides)) ?? 0
        totalDistanceMeters = (try? c.decode(Double.self, forKey: .totalDistanceMeters)) ?? 0.0
        longestDistanceMeters = (try? c.decode(Double.self, forKey: .longestDistanceMeters)) ?? 0.0
        longestDurationMillis = (try? c.decode(Int64.self, forKey: .longestDurationMillis)) ?? 0
        lastRideFinishedAtMillis = (try? c.decode(Int64.self, forKey: .lastRideFinishedAtMillis)) ?? 0
        currentWeekStartEpochDay = (try? c.decode(Int.self, forKey: .currentWeekStartEpochDay)) ?? 0
        currentWeekRideCount = (try? c.decode(Int.self, forKey: .currentWeekRideCount)) ?? 0
        currentWeekDistanceMeters = (try? c.decode(Double.self, forKey: .currentWeekDistanceMeters)) ?? 0.0
        streakWeeks = (try? c.decode(Int.self, forKey: .streakWeeks)) ?? 0
        lastStreakWeekStartEpochDay = (try? c.decode(Int.self, forKey: .lastStreakWeekStartEpochDay)) ?? 0
        freezeAvailable = (try? c.decode(Bool.self, forKey: .freezeAvailable)) ?? true
        lastRecapShownWeekStartEpochDay = (try? c.decode(Int.self, forKey: .lastRecapShownWeekStartEpochDay)) ?? 0
        processedRideIds = (try? c.decode([String].self, forKey: .processedRideIds)) ?? []
    }
}

/// Pure result of folding one `GoodRideSummary` in. Facts only — features map facts to
/// UI/telemetry downstream (B1 reveal, etc.). Identical shape to Android's transition.
nonisolated struct RideStatsTransition {
    let rideId: String
    let alreadyProcessed: Bool
    let isFirstRide: Bool
    let isDistancePR: Bool
    let isDurationPR: Bool
    let milestoneRideCount: Int?
    let totalRides: Int
    let distanceMeters: Double
    let durationMillis: Int64
    let weekKey: String
    let weekRideCount: Int
    let weekDistanceMeters: Double
    let streakWeeks: Int
    let isFirstRideOfWeek: Bool
    let streakAdvanced: Bool
    /// True when this ride's week-rollover forgave a single missed week (B3 auto-freeze).
    let streakFroze: Bool
    /// True when B1/B4 post-ride celebrations must not be presented for this ride.
    /// Parity with Android `RideStatsTransition.suppressPostRideCelebrations`.
    let suppressPostRideCelebrations: Bool

    /// Explicit memberwise init: the new flag is last and defaults to `false`, so every existing
    /// construction site (and test) keeps compiling while the fields stay `let`.
    init(
        rideId: String,
        alreadyProcessed: Bool,
        isFirstRide: Bool,
        isDistancePR: Bool,
        isDurationPR: Bool,
        milestoneRideCount: Int?,
        totalRides: Int,
        distanceMeters: Double,
        durationMillis: Int64,
        weekKey: String,
        weekRideCount: Int,
        weekDistanceMeters: Double,
        streakWeeks: Int,
        isFirstRideOfWeek: Bool,
        streakAdvanced: Bool,
        streakFroze: Bool,
        suppressPostRideCelebrations: Bool = false
    ) {
        self.rideId = rideId
        self.alreadyProcessed = alreadyProcessed
        self.isFirstRide = isFirstRide
        self.isDistancePR = isDistancePR
        self.isDurationPR = isDurationPR
        self.milestoneRideCount = milestoneRideCount
        self.totalRides = totalRides
        self.distanceMeters = distanceMeters
        self.durationMillis = durationMillis
        self.weekKey = weekKey
        self.weekRideCount = weekRideCount
        self.weekDistanceMeters = weekDistanceMeters
        self.streakWeeks = streakWeeks
        self.isFirstRideOfWeek = isFirstRideOfWeek
        self.streakAdvanced = streakAdvanced
        self.streakFroze = streakFroze
        self.suppressPostRideCelebrations = suppressPostRideCelebrations
    }
}

/// B2 immutable snapshot of a completed (rolled-over) week for the recap card. Gain-framed
/// facts only; `streakWeeks` is the B3 line. Parity with Android `WeeklyRecap`.
nonisolated struct WeeklyRecap: Identifiable, Equatable {
    let weekKey: String
    let weekStartEpochDay: Int
    let rideCount: Int
    let distanceMeters: Double
    let streakWeeks: Int
    var id: Int { weekStartEpochDay }
}

/// Single source of truth for Monday-anchored week boundaries (parity with Android `WeekKey`).
/// Inject the `Calendar` for deterministic timezone/DST tests.
nonisolated enum WeekKey {
    /// A Monday-first ISO-8601 calendar in the given time zone.
    static func mondayAnchored(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .iso8601) // ISO: Monday is the first weekday
        cal.timeZone = timeZone
        return cal
    }

    private static let epoch = Date(timeIntervalSince1970: 0)

    /// A fixed UTC ISO-8601 calendar used only to turn a Y/M/D into an exact epoch-day and back,
    /// mirroring java.time's `LocalDate` (which is date-only and timezone-free). Kept private so
    /// the timezone-mixing bug (local-midnight Monday vs a UTC-fixed instant) cannot recur.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Whole days from the Unix epoch to the Monday of the week containing `date`, evaluated in
    /// `calendar`'s time zone. Matches Android `WeekKey.weekStartEpochDay` (LocalDate.toEpochDay)
    /// in EVERY zone: it resolves the local Monday's calendar date (Y/M/D), then reconstructs that
    /// date at UTC midnight so the day count is an exact multiple of 86400 — no instant-vs-midnight
    /// truncation error. Still Monday-anchored and still increments by exactly 7 per week.
    static func weekStartEpochDay(_ date: Date, calendar: Calendar) -> Int {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
        let monday = interval?.start ?? calendar.startOfDay(for: date)   // LOCAL Monday midnight
        let ymd = calendar.dateComponents([.year, .month, .day], from: monday)
        let utcMidnight = utcCalendar.date(from: ymd) ?? monday
        return utcCalendar.dateComponents([.day], from: epoch, to: utcMidnight).day ?? 0
    }

    /// ISO-8601 week label "YYYY-Www" for a Monday epoch-day. An epoch-day is a pure, timezone-free
    /// date (exactly like `LocalDate.ofEpochDay`), so the label is ALWAYS computed in UTC and the
    /// `calendar` argument is intentionally ignored — it is retained only for source compatibility
    /// with existing call sites. Matches Android `WeekKey.label` in every zone. Do NOT reintroduce a
    /// non-UTC calendar here: that is the exact bug this rewrite fixes.
    static func label(weekStartEpochDay: Int, calendar: Calendar = utcCalendar) -> String {
        _ = calendar   // deliberately unused; see doc comment above.
        let monday = Date(timeIntervalSince1970: TimeInterval(weekStartEpochDay) * 86_400)
        let comps = utcCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: monday)
        return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }
}

/// Pure reducer: `(old, summary, calendar) -> (new, transition)`. No I/O, no analytics.
/// Idempotent by ride ID; PR flags compare against the pre-update snapshot; weekly streak
/// counts consecutive Monday-anchored active weeks. Mirrors Android `RideStatsReducer`.
nonisolated enum RideStatsReducer {
    static let milestones = [10, 25, 50, 100, 250, 500, 1000]

    static func reduce(
        _ old: RideStats,
        _ summary: GoodRideSummary,
        _ calendar: Calendar
    ) -> (RideStats, RideStatsTransition) {

        let finishedDate = Date(timeIntervalSince1970: Double(summary.finishedAtMillis) / 1000.0)
        let weekStart = WeekKey.weekStartEpochDay(finishedDate, calendar: calendar)

        // Exclusion/idempotency -> no-op. Samples deliberately stay out of processedRideIds;
        // their terminal seed state, not stats persistence, owns deletion permanence.
        if summary.isSample || old.processedRideIds.contains(summary.rideId) {
            let noOp = RideStatsTransition(
                rideId: summary.rideId,
                alreadyProcessed: true,
                isFirstRide: false,
                isDistancePR: false,
                isDurationPR: false,
                milestoneRideCount: nil,
                totalRides: old.totalRides,
                distanceMeters: summary.distanceMeters,
                durationMillis: summary.durationMillis,
                weekKey: WeekKey.label(
                    weekStartEpochDay: old.currentWeekStartEpochDay != 0 ? old.currentWeekStartEpochDay : weekStart,
                    calendar: calendar),
                weekRideCount: old.currentWeekRideCount,
                weekDistanceMeters: old.currentWeekDistanceMeters,
                streakWeeks: old.streakWeeks,
                isFirstRideOfWeek: false,
                streakAdvanced: false,
                streakFroze: false,
                suppressPostRideCelebrations: summary.suppressPostRideCelebrations
            )
            return (old, noOp)
        }

        let isFirstRide = old.totalRides == 0
        let isDistancePR = !isFirstRide && summary.distanceMeters > old.longestDistanceMeters
        let isDurationPR = !isFirstRide && summary.durationMillis > old.longestDurationMillis

        let newTotalRides = old.totalRides + 1
        let milestoneRideCount = milestones.contains(newTotalRides) ? newTotalRides : nil

        let sameWeek = old.totalRides > 0 && old.currentWeekStartEpochDay == weekStart
        let isFirstRideOfWeek = !sameWeek
        let newWeekRideCount = sameWeek ? old.currentWeekRideCount + 1 : 1
        let newWeekDistance = sameWeek ? old.currentWeekDistanceMeters + summary.distanceMeters : summary.distanceMeters

        // B3 single-miss forgiveness (parity with Android): gap between active weeks is a
        // multiple of 7. 7 -> consecutive; 14 -> one miss (auto-freeze if a token is available);
        // >14 or backwards -> reset. A token is consumed by a forgiven miss, refilled by any
        // active week. Loss is NEVER surfaced (telemetry-only `froze`).
        var newStreakWeeks = old.streakWeeks
        var newLastStreakWeekStart = old.lastStreakWeekStartEpochDay
        var newFreezeAvailable = old.freezeAvailable
        var streakAdvanced = false
        var streakFroze = false
        if isFirstRideOfWeek {
            let gapDays = weekStart - old.lastStreakWeekStartEpochDay
            if old.lastStreakWeekStartEpochDay == 0 {
                newStreakWeeks = 1
                newFreezeAvailable = true
            } else if gapDays == 7 {
                newStreakWeeks = old.streakWeeks + 1
                newFreezeAvailable = true
            } else if gapDays == 14 && old.freezeAvailable {
                newStreakWeeks = old.streakWeeks + 1
                newFreezeAvailable = false
                streakFroze = true
            } else if gapDays == 0 {
                newStreakWeeks = old.streakWeeks
            } else {
                newStreakWeeks = 1
                newFreezeAvailable = true
            }
            newLastStreakWeekStart = weekStart
            streakAdvanced = newStreakWeeks > old.streakWeeks
        }

        var newProcessed = old.processedRideIds
        newProcessed.append(summary.rideId)
        if newProcessed.count > RideStats.maxProcessedIds {
            newProcessed = Array(newProcessed.suffix(RideStats.maxProcessedIds))
        }

        var newStats = old
        newStats.schemaVersion = RideStats.currentSchemaVersion
        newStats.totalRides = newTotalRides
        newStats.totalDistanceMeters = old.totalDistanceMeters + summary.distanceMeters
        newStats.longestDistanceMeters = max(old.longestDistanceMeters, summary.distanceMeters)
        newStats.longestDurationMillis = max(old.longestDurationMillis, summary.durationMillis)
        newStats.lastRideFinishedAtMillis = summary.finishedAtMillis
        newStats.currentWeekStartEpochDay = weekStart
        newStats.currentWeekRideCount = newWeekRideCount
        newStats.currentWeekDistanceMeters = newWeekDistance
        newStats.streakWeeks = newStreakWeeks
        newStats.lastStreakWeekStartEpochDay = newLastStreakWeekStart
        newStats.freezeAvailable = newFreezeAvailable
        newStats.processedRideIds = newProcessed

        let transition = RideStatsTransition(
            rideId: summary.rideId,
            alreadyProcessed: false,
            isFirstRide: isFirstRide,
            isDistancePR: isDistancePR,
            isDurationPR: isDurationPR,
            milestoneRideCount: milestoneRideCount,
            totalRides: newTotalRides,
            distanceMeters: summary.distanceMeters,
            durationMillis: summary.durationMillis,
            weekKey: WeekKey.label(weekStartEpochDay: weekStart, calendar: calendar),
            weekRideCount: newWeekRideCount,
            weekDistanceMeters: newWeekDistance,
            streakWeeks: newStreakWeeks,
            isFirstRideOfWeek: isFirstRideOfWeek,
            streakAdvanced: streakAdvanced,
            streakFroze: streakFroze,
            suppressPostRideCelebrations: summary.suppressPostRideCelebrations
        )

        return (newStats, transition)
    }
}

/// Pure B2 decision: given `RideStats` and "now", is there a completed week worth recapping?
/// Parity with Android `WeeklyRecapSelector`. Gain-framed: silent on zero-ride weeks and while
/// still inside the active week; dedup'd via `lastRecapShownWeekStartEpochDay`.
nonisolated enum WeeklyRecapSelector {
    static func select(_ stats: RideStats, now: Date, calendar: Calendar) -> WeeklyRecap? {
        let thisWeekStart = WeekKey.weekStartEpochDay(now, calendar: calendar)
        guard stats.currentWeekStartEpochDay != 0 else { return nil }          // never rode
        guard stats.currentWeekStartEpochDay < thisWeekStart else { return nil } // still active week
        guard stats.currentWeekRideCount > 0 else { return nil }               // nothing to celebrate
        guard stats.lastRecapShownWeekStartEpochDay != stats.currentWeekStartEpochDay else { return nil }
        return WeeklyRecap(
            weekKey: WeekKey.label(weekStartEpochDay: stats.currentWeekStartEpochDay, calendar: calendar),
            weekStartEpochDay: stats.currentWeekStartEpochDay,
            rideCount: stats.currentWeekRideCount,
            distanceMeters: stats.currentWeekDistanceMeters,
            streakWeeks: stats.streakWeeks
        )
    }
}
