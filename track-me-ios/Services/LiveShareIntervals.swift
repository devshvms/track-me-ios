import Foundation

/// TASK-368 / SCOPE_1.9.3 §1.6: tracks active Live Share intervals within a single recorded ride
/// and resolves `"FULL"` vs `"PARTIAL"` mode identically to Android (`LiveShareIntervals.kt`).
struct LiveShareInterval: Equatable, Hashable, Codable {
    let startMillis: Int64
    let endMillis: Int64

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startMillis) / 1_000.0)
    }

    var endDate: Date {
        Date(timeIntervalSince1970: TimeInterval(endMillis) / 1_000.0)
    }
}

enum LiveShareIntervals {
    static let modeFull = "FULL"
    static let modePartial = "PARTIAL"

    /// Direct Share starts `TrackingManager` and the live session sequentially; 20s absorbs handoff latency.
    private static let edgeToleranceMillis: Int64 = 20_000
    private static let fullCoverageThreshold: Double = 0.90

    static func normalize(
        _ intervals: [LiveShareInterval],
        minStartMillis: Int64 = .min,
        maxEndMillis: Int64 = .max
    ) -> [LiveShareInterval] {
        let sorted = intervals.compactMap { interval -> LiveShareInterval? in
            let start = max(interval.startMillis, minStartMillis)
            let end = min(interval.endMillis, maxEndMillis)
            return end > start ? LiveShareInterval(startMillis: start, endMillis: end) : nil
        }
        .sorted { $0.startMillis < $1.startMillis }

        guard var current = sorted.first else { return [] }
        var merged: [LiveShareInterval] = []
        merged.reserveCapacity(sorted.count)

        for next in sorted.dropFirst() {
            if next.startMillis <= current.endMillis {
                current = LiveShareInterval(
                    startMillis: current.startMillis,
                    endMillis: max(current.endMillis, next.endMillis)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    static func parse(_ json: String?) -> [LiveShareInterval] {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            return []
        }

        let intervals = rawArray.compactMap { pair -> LiveShareInterval? in
            guard pair.count >= 2,
                  let start = (pair[0] as? NSNumber)?.int64Value,
                  let end = (pair[1] as? NSNumber)?.int64Value,
                  start > 0,
                  end > start else {
                return nil
            }
            return LiveShareInterval(startMillis: start, endMillis: end)
        }
        return normalize(intervals)
    }

    static func serialize(_ intervals: [LiveShareInterval]) -> String? {
        let normalized = normalize(intervals)
        guard !normalized.isEmpty else { return nil }
        let payload = normalized.map { [$0.startMillis, $0.endMillis] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func resolveMode(
        rideStartMillis: Int64,
        rideEndMillis: Int64,
        intervals: [LiveShareInterval]
    ) -> String? {
        guard rideEndMillis > rideStartMillis else { return nil }
        let normalized = normalize(
            intervals,
            minStartMillis: rideStartMillis,
            maxEndMillis: rideEndMillis
        )
        guard !normalized.isEmpty else { return nil }

        let coveredMillis = normalized.reduce(Int64(0)) { $0 + ($1.endMillis - $1.startMillis) }
        guard coveredMillis > 0 else { return nil }

        let totalRideMillis = max(Int64(1), rideEndMillis - rideStartMillis)
        let startedAtOrigin = (normalized.first!.startMillis - rideStartMillis) <= edgeToleranceMillis
        let lastedToEnd = (rideEndMillis - normalized.last!.endMillis) <= edgeToleranceMillis
        let ratio = Double(coveredMillis) / Double(totalRideMillis)

        if ratio >= fullCoverageThreshold || (normalized.count == 1 && startedAtOrigin && lastedToEnd) {
            return modeFull
        } else {
            return modePartial
        }
    }

    static func containsTimestamp(_ intervals: [LiveShareInterval], timestampMillis: Int64) -> Bool {
        intervals.contains { timestampMillis >= $0.startMillis && timestampMillis <= $0.endMillis }
    }

    static func containsDate(_ intervals: [LiveShareInterval], date: Date) -> Bool {
        containsTimestamp(intervals, timestampMillis: Int64((date.timeIntervalSince1970 * 1_000.0).rounded()))
    }
}

/// Thread-safe, persistence-backed accumulator for active Live Share spans during a ride.
/// Survives app backgrounding/restarts via UserDefaults keyed by active ride UUID.
final class LiveShareIntervalTracker {
    private let defaults: UserDefaults
    private static let rideIdKey = "live_share_active_ride_id"
    private static let intervalsKey = "live_share_recorded_intervals_json"
    private static let openStartMsKey = "live_share_open_interval_start_ms"

    private var trackedRideId: String?
    private var completedIntervals: [LiveShareInterval] = []
    private var openStartMillis: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFromDefaults()
    }

    func beginRide(rideId: UUID) {
        trackedRideId = rideId.uuidString
        completedIntervals = []
        openStartMillis = nil
        persist()
    }

    func bindExistingOrRestoreRide(rideId: UUID) {
        if trackedRideId != rideId.uuidString {
            restoreFromDefaults()
            if trackedRideId != rideId.uuidString {
                beginRide(rideId: rideId)
            }
        }
    }

    func markLiveShareStarted(at date: Date = Date(), activeRideId: UUID?) {
        guard let activeRideId else { return }
        bindExistingOrRestoreRide(rideId: activeRideId)
        guard openStartMillis == nil else { return }
        openStartMillis = Int64((date.timeIntervalSince1970 * 1_000.0).rounded())
        persist()
    }

    func markLiveShareEnded(at date: Date = Date()) {
        guard trackedRideId != nil, let startMs = openStartMillis else { return }
        let endMs = Int64((date.timeIntervalSince1970 * 1_000.0).rounded())
        if endMs > startMs {
            completedIntervals.append(LiveShareInterval(startMillis: startMs, endMillis: endMs))
            completedIntervals = LiveShareIntervals.normalize(completedIntervals)
        }
        openStartMillis = nil
        persist()
    }

    func finalizeIntervals(for rideId: UUID, endedAt: Date) -> [LiveShareInterval] {
        guard trackedRideId == rideId.uuidString else { return [] }
        if let startMs = openStartMillis {
            let endMs = Int64((endedAt.timeIntervalSince1970 * 1_000.0).rounded())
            if endMs > startMs {
                completedIntervals.append(LiveShareInterval(startMillis: startMs, endMillis: endMs))
            }
            openStartMillis = nil
        }
        let result = LiveShareIntervals.normalize(completedIntervals)
        clear()
        return result
    }

    func currentIntervalsSnapshot(rideId: UUID) -> [LiveShareInterval] {
        guard trackedRideId == rideId.uuidString else { return [] }
        var copy = completedIntervals
        if let startMs = openStartMillis {
            let nowMs = Int64((Date().timeIntervalSince1970 * 1_000.0).rounded())
            if nowMs > startMs {
                copy.append(LiveShareInterval(startMillis: startMs, endMillis: nowMs))
            }
        }
        return LiveShareIntervals.normalize(copy)
    }

    func clear() {
        trackedRideId = nil
        completedIntervals = []
        openStartMillis = nil
        defaults.removeObject(forKey: Self.rideIdKey)
        defaults.removeObject(forKey: Self.intervalsKey)
        defaults.removeObject(forKey: Self.openStartMsKey)
    }

    private func persist() {
        guard let trackedRideId else {
            clear()
            return
        }
        defaults.set(trackedRideId, forKey: Self.rideIdKey)
        if let serialized = LiveShareIntervals.serialize(completedIntervals) {
            defaults.set(serialized, forKey: Self.intervalsKey)
        } else {
            defaults.removeObject(forKey: Self.intervalsKey)
        }
        if let openStartMillis {
            defaults.set(NSNumber(value: openStartMillis), forKey: Self.openStartMsKey)
        } else {
            defaults.removeObject(forKey: Self.openStartMsKey)
        }
    }

    private func restoreFromDefaults() {
        trackedRideId = defaults.string(forKey: Self.rideIdKey)
        completedIntervals = LiveShareIntervals.parse(defaults.string(forKey: Self.intervalsKey))
        if let number = defaults.object(forKey: Self.openStartMsKey) as? NSNumber {
            openStartMillis = number.int64Value
        } else {
            openStartMillis = nil
        }
    }
}
