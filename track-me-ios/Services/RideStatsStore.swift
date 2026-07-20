import Foundation

/// iOS persistence adapter for the shared A1 stats layer (parity with Android `RideStatsStore`).
///
/// Implemented as an `actor` so all read-modify-write mutations are serialized — an overlap
/// between normal finalization and orphaned-ride recovery can never lose an increment.
/// Persists FIRST, then returns the transition. Telemetry is emitted by the feature layer,
/// never here. Fails closed: an unreadable/corrupt/older blob resets to a fresh versioned
/// store rather than crashing ride saving.
actor RideStatsStore {
    static let shared = RideStatsStore()

    private let defaults: UserDefaults
    private let key = "ride_stats_v1"
    private var cached: RideStats

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = RideStatsStore.load(defaults: defaults, key: "ride_stats_v1")
    }

    /// Fold one good ride into the store and return the resulting transition.
    /// Idempotent by ride ID (recovery-after-finalize is safe). `calendar` injected for tests.
    @discardableResult
    func recordGoodRide(
        _ summary: GoodRideSummary,
        calendar: Calendar = WeekKey.mondayAnchored()
    ) -> RideStatsTransition {
        let (new, transition) = RideStatsReducer.reduce(cached, summary, calendar)
        if !transition.alreadyProcessed {
            cached = new
            persist(new)
        }
        return transition
    }

    /// Current snapshot for UI (B2 recap, B3 streak badge).
    func current() -> RideStats { cached }

    // MARK: - persistence

    private static func load(defaults: UserDefaults, key: String) -> RideStats {
        guard let data = defaults.data(forKey: key) else { return RideStats() }
        do {
            let stats = try JSONDecoder().decode(RideStats.self, from: data)
            // Only v1 is known; anything else fails closed to a fresh store.
            return stats.schemaVersion == RideStats.currentSchemaVersion ? stats : RideStats()
        } catch {
            return RideStats()
        }
    }

    private func persist(_ stats: RideStats) {
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: key)
        }
    }
}
