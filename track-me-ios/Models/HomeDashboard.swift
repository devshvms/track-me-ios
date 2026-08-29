import Foundation

nonisolated struct HomeWeeklyBucket: Codable, Equatable, Sendable {
    let weekStartEpochDay: Int
    let activityCount: Int
    let distanceMeters: Double
    let activeDurationMillis: Int64
    let distanceByPersona: [Double]
}

nonisolated struct HomeRecentActivity: Codable, Equatable, Sendable {
    let localId: UUID
    let persona: RidePersona
    let startedAtEpochMillis: Int64
    let distanceMeters: Double
    let activeDurationMillis: Int64
    let avgSpeedMps: Double
    let hasRoute: Bool
}

nonisolated struct HomePersonaCount: Codable, Equatable, Sendable {
    let persona: RidePersona
    let count: Int
}

nonisolated enum HomeInsightMetric: String, Codable, Sendable {
    case distance
    case activeDuration
}

nonisolated enum HomeInsightDirection: String, Codable, Sendable {
    case lower
    case stable
    case higher
}

nonisolated struct HomeInsightPeriod: Codable, Equatable, Sendable {
    let startEpochDay: Int
    let endEpochDay: Int
}

nonisolated enum HomeInsight: Codable, Equatable, Sendable {
    case returning(persona: RidePersona, inactiveDays: Int)
    case periodComparison(
        metric: HomeInsightMetric,
        direction: HomeInsightDirection,
        currentPeriod: HomeInsightPeriod,
        comparisonPeriod: HomeInsightPeriod,
        currentValue: Double,
        comparisonValue: Double,
        percentDelta: Double
    )
    case dominantPersona(
        persona: RidePersona,
        personaCount: Int,
        totalCount: Int,
        windowStartEpochDay: Int,
        windowEndEpochDay: Int
    )

    var analyticsValue: String {
        switch self {
        case .returning: "return"
        case .periodComparison: "period_comparison"
        case .dominantPersona: "dominant_persona"
        }
    }
}

nonisolated struct HomeDashboardSummary: Codable, Equatable, Sendable {
    let currentWeek: HomeWeeklyBucket
    let lifetimeActivityCount: Int
    let lifetimeDistanceMeters: Double
    let lifetimeActiveDurationMillis: Int64
    let displayStreakWeeks: Int
    let latestActivity: HomeRecentActivity?
    /// Oldest to newest, including zero weeks, so the chart never shifts meaning.
    let weeklyBuckets: [HomeWeeklyBucket]
    let personaCounts: [HomePersonaCount]
    let insight: HomeInsight?

    var historyBucket: String {
        switch lifetimeActivityCount {
        case 0: "empty"
        case 1, 2: "early"
        default: "established"
        }
    }

    static func empty(now: Date = Date(), timeZone: TimeZone = .current) -> HomeDashboardSummary {
        let today = HomeCalendar.epochDay(for: now, timeZone: timeZone)
        let week = HomeCalendar.mondayEpochDay(containing: today)
        return HomeDashboardSummary(
            currentWeek: HomeWeeklyBucket(
                weekStartEpochDay: week,
                activityCount: 0,
                distanceMeters: 0,
                activeDurationMillis: 0,
                distanceByPersona: []
            ),
            lifetimeActivityCount: 0,
            lifetimeDistanceMeters: 0,
            lifetimeActiveDurationMillis: 0,
            displayStreakWeeks: 0,
            latestActivity: nil,
            weeklyBuckets: [],
            personaCounts: [],
            insight: nil
        )
    }
}

nonisolated struct HomeDashboardRideMetadata: Equatable, Sendable {
    let localId: UUID
    let persona: RidePersona
    let startedAt: Date
    let startZoneId: String?
    let distanceMeters: Double
    let activeDurationMillis: Int64
    let avgSpeedMps: Double
    let pointCount: Int
}

nonisolated enum HomePresentationMode: Equatable, Sendable {
    case idleDashboard
    case activeTrackingMap
    case explicitGroupMap
}

nonisolated enum HomePresentationModePolicy {
    static func resolve(isTrackingIdle: Bool, explicitGroupMap: Bool) -> HomePresentationMode {
        if !isTrackingIdle { return .activeTrackingMap }
        if explicitGroupMap { return .explicitGroupMap }
        return .idleDashboard
    }
}

nonisolated enum HomeDashboardSelector {
    private static let chartWeeks = 8
    private static let insightActiveWeeks = 8
    private static let stableDeadbandPercent = 10.0

    static func select(
        rides: [HomeDashboardRideMetadata],
        now: Date = Date(),
        fallbackTimeZone: TimeZone = .current
    ) -> HomeDashboardSummary {
        let today = HomeCalendar.epochDay(for: now, timeZone: fallbackTimeZone)
        let currentWeekStart = HomeCalendar.mondayEpochDay(containing: today)
        let sorted = rides.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.localId.uuidString > $1.localId.uuidString
        }
        let grouped = Dictionary(grouping: sorted) {
            HomeCalendar.mondayEpochDay(containing: localEpochDay($0, fallbackTimeZone: fallbackTimeZone))
        }
        let chartBuckets = (0..<chartWeeks).reversed().map { weeksAgo in
            let start = currentWeekStart - weeksAgo * 7
            return weeklyBucket(start: start, rides: grouped[start] ?? [])
        }
        let currentWeek = chartBuckets.last ?? weeklyBucket(start: currentWeekStart, rides: [])
        let activeWeekStarts = grouped.keys.sorted(by: >)
        let recentActiveWeeks = Set(activeWeekStarts.prefix(insightActiveWeeks))
        let recentPersonaRides = sorted.filter {
            recentActiveWeeks.contains(
                HomeCalendar.mondayEpochDay(
                    containing: localEpochDay($0, fallbackTimeZone: fallbackTimeZone)
                )
            )
        }
        let personaCounts = RidePersona.allCases.compactMap { persona -> HomePersonaCount? in
            let count = recentPersonaRides.lazy.filter { $0.persona == persona }.count
            return count > 0 ? HomePersonaCount(persona: persona, count: count) : nil
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return personaOrder($0.persona) < personaOrder($1.persona)
        }

        return HomeDashboardSummary(
            currentWeek: currentWeek,
            lifetimeActivityCount: sorted.count,
            lifetimeDistanceMeters: sorted.reduce(0) { $0 + $1.distanceMeters },
            lifetimeActiveDurationMillis: sorted.reduce(Int64(0)) { $0 + $1.activeDurationMillis },
            displayStreakWeeks: displayStreak(activeWeeks: activeWeekStarts, currentWeek: currentWeekStart),
            latestActivity: sorted.first.map {
                HomeRecentActivity(
                    localId: $0.localId,
                    persona: $0.persona,
                    startedAtEpochMillis: Int64($0.startedAt.timeIntervalSince1970 * 1_000),
                    distanceMeters: $0.distanceMeters,
                    activeDurationMillis: $0.activeDurationMillis,
                    avgSpeedMps: $0.avgSpeedMps,
                    hasRoute: $0.pointCount > 0
                )
            },
            weeklyBuckets: chartBuckets,
            personaCounts: personaCounts,
            insight: selectInsight(
                rides: sorted,
                grouped: grouped,
                activeWeekStarts: activeWeekStarts,
                currentWeekStart: currentWeekStart,
                today: today,
                fallbackTimeZone: fallbackTimeZone
            )
        )
    }

    private static func selectInsight(
        rides: [HomeDashboardRideMetadata],
        grouped: [Int: [HomeDashboardRideMetadata]],
        activeWeekStarts: [Int],
        currentWeekStart: Int,
        today: Int,
        fallbackTimeZone: TimeZone
    ) -> HomeInsight? {
        guard rides.count >= 3 else { return nil }
        if let returning = returnAfterInactivity(rides, fallbackTimeZone: fallbackTimeZone) {
            return returning
        }
        if let comparison = previousActiveWeekComparison(
            grouped: grouped,
            activeWeekStarts: activeWeekStarts,
            currentWeekStart: currentWeekStart,
            today: today,
            fallbackTimeZone: fallbackTimeZone
        ) {
            return comparison
        }
        if let comparison = fourWeekComparison(
            grouped: grouped,
            activeWeekStarts: activeWeekStarts,
            currentWeekStart: currentWeekStart
        ) {
            return comparison
        }
        return dominantPersona(
            rides: rides,
            activeWeekStarts: activeWeekStarts,
            fallbackTimeZone: fallbackTimeZone
        )
    }

    private static func returnAfterInactivity(
        _ rides: [HomeDashboardRideMetadata],
        fallbackTimeZone: TimeZone
    ) -> HomeInsight? {
        let latest = localEpochDay(rides[0], fallbackTimeZone: fallbackTimeZone)
        let previous = localEpochDay(rides[1], fallbackTimeZone: fallbackTimeZone)
        let inactiveDays = latest - previous
        guard inactiveDays >= 14 else { return nil }
        return .returning(persona: rides[0].persona, inactiveDays: inactiveDays)
    }

    private static func previousActiveWeekComparison(
        grouped: [Int: [HomeDashboardRideMetadata]],
        activeWeekStarts: [Int],
        currentWeekStart: Int,
        today: Int,
        fallbackTimeZone: TimeZone
    ) -> HomeInsight? {
        let current = grouped[currentWeekStart] ?? []
        guard !current.isEmpty,
              let comparisonStart = activeWeekStarts.first(where: {
                  $0 < currentWeekStart && currentWeekStart - $0 <= 28
              }) else { return nil }
        let elapsedDay = today - currentWeekStart
        let comparisonEnd = comparisonStart + elapsedDay
        let comparisonRides = (grouped[comparisonStart] ?? []).filter {
            localEpochDay($0, fallbackTimeZone: fallbackTimeZone) <= comparisonEnd
        }
        return comparison(
            currentValue: current.reduce(0) { $0 + $1.distanceMeters },
            comparisonValue: comparisonRides.reduce(0) { $0 + $1.distanceMeters },
            current: HomeInsightPeriod(startEpochDay: currentWeekStart, endEpochDay: today),
            previous: HomeInsightPeriod(startEpochDay: comparisonStart, endEpochDay: comparisonEnd)
        )
    }

    private static func fourWeekComparison(
        grouped: [Int: [HomeDashboardRideMetadata]],
        activeWeekStarts: [Int],
        currentWeekStart: Int
    ) -> HomeInsight? {
        let completedActive = activeWeekStarts.filter { $0 < currentWeekStart }
        guard completedActive.count >= 8 else { return nil }
        let currentWeeks = Array(completedActive.prefix(4))
        let precedingWeeks = Array(completedActive.dropFirst(4).prefix(4))
        let currentValue = currentWeeks.reduce(0) { total, week in
            total + (grouped[week] ?? []).reduce(0) { $0 + $1.distanceMeters }
        } / 4
        let previousValue = precedingWeeks.reduce(0) { total, week in
            total + (grouped[week] ?? []).reduce(0) { $0 + $1.distanceMeters }
        } / 4
        return comparison(
            currentValue: currentValue,
            comparisonValue: previousValue,
            current: HomeInsightPeriod(
                startEpochDay: currentWeeks.last ?? currentWeekStart,
                endEpochDay: (currentWeeks.first ?? currentWeekStart) + 6
            ),
            previous: HomeInsightPeriod(
                startEpochDay: precedingWeeks.last ?? currentWeekStart,
                endEpochDay: (precedingWeeks.first ?? currentWeekStart) + 6
            )
        )
    }

    private static func dominantPersona(
        rides: [HomeDashboardRideMetadata],
        activeWeekStarts: [Int],
        fallbackTimeZone: TimeZone
    ) -> HomeInsight? {
        let window = Array(activeWeekStarts.prefix(insightActiveWeeks))
        guard let windowStart = window.last, let windowEnd = window.first else { return nil }
        let candidates = rides.filter {
            window.contains(
                HomeCalendar.mondayEpochDay(
                    containing: localEpochDay($0, fallbackTimeZone: fallbackTimeZone)
                )
            )
        }
        guard candidates.count >= 3 else { return nil }
        let counts = Dictionary(grouping: candidates, by: \.persona).mapValues(\.count)
        guard let maximum = counts.values.max() else { return nil }
        let leaders = counts.filter { $0.value == maximum }.map(\.key)
        guard leaders.count == 1, let persona = leaders.first else { return nil }
        return .dominantPersona(
            persona: persona,
            personaCount: maximum,
            totalCount: candidates.count,
            windowStartEpochDay: windowStart,
            windowEndEpochDay: windowEnd + 6
        )
    }

    private static func comparison(
        currentValue: Double,
        comparisonValue: Double,
        current: HomeInsightPeriod,
        previous: HomeInsightPeriod
    ) -> HomeInsight? {
        guard comparisonValue > 0 else { return nil }
        let delta = ((currentValue - comparisonValue) / comparisonValue) * 100
        let direction: HomeInsightDirection
        if abs(delta) < stableDeadbandPercent {
            direction = .stable
        } else {
            direction = delta > 0 ? .higher : .lower
        }
        return .periodComparison(
            metric: .distance,
            direction: direction,
            currentPeriod: current,
            comparisonPeriod: previous,
            currentValue: currentValue,
            comparisonValue: comparisonValue,
            percentDelta: delta
        )
    }

    private static func displayStreak(activeWeeks: [Int], currentWeek: Int) -> Int {
        guard let newest = activeWeeks.first,
              newest == currentWeek || newest == currentWeek - 7 else { return 0 }
        var streak = 1
        var cursor = newest
        for week in activeWeeks.dropFirst() {
            guard week == cursor - 7 else { break }
            streak += 1
            cursor = week
        }
        return streak
    }

    private static func weeklyBucket(
        start: Int,
        rides: [HomeDashboardRideMetadata]
    ) -> HomeWeeklyBucket {
        HomeWeeklyBucket(
            weekStartEpochDay: start,
            activityCount: rides.count,
            distanceMeters: rides.reduce(0) { $0 + $1.distanceMeters },
            activeDurationMillis: rides.reduce(Int64(0)) { $0 + $1.activeDurationMillis },
            distanceByPersona: RidePersona.allCases.map { p in
                rides.filter { $0.persona == p }.reduce(0) { $0 + $1.distanceMeters }
            }
        )
    }

    private static func localEpochDay(
        _ ride: HomeDashboardRideMetadata,
        fallbackTimeZone: TimeZone
    ) -> Int {
        let timeZone = ride.startZoneId.flatMap(TimeZone.init(identifier:)) ?? fallbackTimeZone
        return HomeCalendar.epochDay(for: ride.startedAt, timeZone: timeZone)
    }

    private static func personaOrder(_ persona: RidePersona) -> Int {
        RidePersona.allCases.firstIndex(of: persona) ?? Int.max
    }
}

nonisolated enum HomeCalendar {
    static func epochDay(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return daysFromCivil(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    static func mondayEpochDay(containing epochDay: Int) -> Int {
        // 1970-01-01 was Thursday, three days after Monday.
        epochDay - floorMod(epochDay + 3, 7)
    }

    static func date(fromEpochDay epochDay: Int, timeZone: TimeZone = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcDate = Date(timeIntervalSince1970: TimeInterval(epochDay) * 86_400)
        let components = utc.dateComponents([.year, .month, .day], from: utcDate)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return local.date(from: components) ?? utcDate
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

nonisolated enum DashboardPersonaPreference {
    static let lastStartedKey = "home.last_started_persona"
    static let onboardingFallbackKey = "home.onboarding_persona"

    static func selected(defaults: UserDefaults = .standard) -> RidePersona {
        if let raw = defaults.string(forKey: lastStartedKey), let persona = RidePersona(rawValue: raw) {
            return persona
        }
        if let raw = defaults.string(forKey: onboardingFallbackKey), let persona = RidePersona(rawValue: raw) {
            return persona
        }
        return .auto
    }

    static func recordOnboardingFallback(
        _ persona: RidePersona,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(persona.rawValue, forKey: onboardingFallbackKey)
    }

    static func recordCommittedStart(
        _ persona: RidePersona,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(persona.rawValue, forKey: lastStartedKey)
    }
}

nonisolated struct HomeTelemetryEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]
}

nonisolated enum HomeTelemetryContract {
    static let allowedInsightTypes: Set<String> = [
        "return", "period_comparison", "dominant_persona"
    ]

    static func dashboardViewed(historyBucket: String) -> HomeTelemetryEvent {
        HomeTelemetryEvent(
            name: "home_dashboard_viewed",
            properties: ["history_bucket": historyBucket]
        )
    }

    static func startTapped(persona: RidePersona, method: String) -> HomeTelemetryEvent {
        HomeTelemetryEvent(
            name: "activity_start_cta_tapped",
            properties: ["persona": persona.rawValue, "method": method]
        )
    }

    static func insightShown(_ insight: HomeInsight) -> HomeTelemetryEvent? {
        guard allowedInsightTypes.contains(insight.analyticsValue) else { return nil }
        return HomeTelemetryEvent(
            name: "home_insight_shown",
            properties: ["insight_type": insight.analyticsValue]
        )
    }

    static func recentOpened(persona: RidePersona) -> HomeTelemetryEvent {
        HomeTelemetryEvent(
            name: "home_recent_activity_opened",
            properties: ["persona": persona.rawValue]
        )
    }

    static let groupMapOpened = HomeTelemetryEvent(
        name: "home_group_map_opened",
        properties: [:]
    )

    static let privacyForbiddenKeys: Set<String> = [
        "ride_id", "ride_title", "route", "latitude", "longitude", "timestamp",
        "name", "email", "account_id"
    ]
}
