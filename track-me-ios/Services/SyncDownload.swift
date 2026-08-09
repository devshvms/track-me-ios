import Foundation
import FirebaseFirestore

struct DownloadedRide: Equatable {
    let localId: UUID
    let firestoreId: String
    let startTime: Date
    let endTime: Date?
    let sourceInfo: String
    let title: String?
    let persona: String
    let points: [DownloadedPoint]
    let distanceMeters: Double?
    let movingDurationMillis: Int64?
    let maxSpeedMps: Double?
    let avgSpeedMps: Double?
    let pointCount: Int?

    var persistedAggregate: RideAggregateSnapshot? {
        guard let distanceMeters,
              let movingDurationMillis,
              let maxSpeedMps,
              let avgSpeedMps else { return nil }
        return RideAggregateSnapshot(
            distanceMeters: RideMetrics.nonNegativeFinite(distanceMeters),
            movingDurationMillis: max(0, movingDurationMillis),
            maxSpeedMps: RideMetrics.nonNegativeFinite(maxSpeedMps),
            avgSpeedMps: RideMetrics.nonNegativeFinite(avgSpeedMps),
            pointCount: max(0, pointCount ?? points.count)
        )
    }

    func aggregate(fallback: RideAggregateSnapshot) -> RideAggregateSnapshot {
        let distance = distanceMeters.map(RideMetrics.nonNegativeFinite) ?? fallback.distanceMeters
        let duration = max(0, movingDurationMillis ?? fallback.movingDurationMillis)
        let average = avgSpeedMps.map(RideMetrics.nonNegativeFinite)
            ?? (duration > 0 ? distance / (Double(duration) / 1_000) : fallback.avgSpeedMps)
        return RideAggregateSnapshot(
            distanceMeters: distance,
            movingDurationMillis: duration,
            maxSpeedMps: maxSpeedMps.map(RideMetrics.nonNegativeFinite) ?? fallback.maxSpeedMps,
            avgSpeedMps: average,
            pointCount: max(0, pointCount ?? fallback.pointCount)
        )
    }
}

struct DownloadedPoint: Equatable {
    let latitude, longitude, altitude, accuracy, speed: Double
    let timestamp: Date
    let isPaused: Bool
}

extension FirestoreSyncManager {
    static func decodeDouble(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func decodeInt64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    static func decodeDate(_ value: Any?) -> Date? {
        switch value {
        case let ts as Timestamp:            return ts.dateValue()
        case let d  as Date:                 return d
        case let n  as NSNumber:
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x >= 1_000_000_000_000 ? x / 1000.0 : x)
        default:                             return nil
        }
    }

    static func parseRideDocument(docId: String, data: [String: Any]) -> DownloadedRide? {
        guard let start = decodeDate(data["startTime"]) else { return nil }
        let end = decodeDate(data["endTime"])
        let localId = (data["id"] as? String).flatMap(UUID.init(uuidString:))
            ?? UUID(uuidString: docId)
            ?? UUID()
        let rawPoints = data["points"] as? [[String: Any]] ?? []
        let points: [DownloadedPoint] = rawPoints.compactMap { p in
            guard let ts = decodeDate(p["timestamp"]) else { return nil }
            return DownloadedPoint(
                latitude:  (p["lat"] as? Double) ?? 0,
                longitude: (p["lng"] as? Double) ?? 0,
                altitude:  (p["altitude"] as? Double) ?? 0,
                accuracy:  (p["accuracy"] as? Double) ?? 0,
                speed:     (p["speed"] as? Double) ?? 0,
                timestamp: ts,
                isPaused:  (p["isPaused"] as? Bool) ?? false
            )
        }
        let wallDurationMillis = end.map {
            Int64(max(0, $0.timeIntervalSince(start) * 1_000))
        }
        let movingDurationMillis = decodeInt64(data["movingDurationMillis"])
            ?? wallDurationMillis.map { max(0, $0 - (decodeInt64(data["pauseDuration"]) ?? 0)) }
        return DownloadedRide(
            localId: localId, firestoreId: docId, startTime: start, endTime: end,
            sourceInfo: (data["sourceInfo"] as? String) ?? "Cloud Sync",
            title: data["title"] as? String,
            persona: (data["persona"] as? String) ?? "AUTO",
            points: points,
            distanceMeters: decodeDouble(data["distance"]),
            movingDurationMillis: movingDurationMillis,
            maxSpeedMps: decodeDouble(data["maxSpeed"]),
            avgSpeedMps: decodeDouble(data["avgSpeed"]),
            pointCount: decodeInt64(data["pointCount"]).map(Int.init)
        )
    }
}
