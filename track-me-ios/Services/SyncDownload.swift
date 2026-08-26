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
    let startZoneId: String?
    let points: [DownloadedPoint]
    let distanceMeters: Double?
    let movingDurationMillis: Int64?
    let maxSpeedMps: Double?
    let avgSpeedMps: Double?
    let pointCount: Int?
    let chunkCount: Int?

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
        decodeFirestoreDouble(value)
    }

    static func decodeInt64(_ value: Any?) -> Int64? {
        decodeFirestoreInt64(value)
    }

    static func decodeDate(_ value: Any?) -> Date? {
        decodeFirestoreDate(value)
    }

    static func parseRideDocument(docId: String, data: [String: Any]) -> DownloadedRide? {
        let points = parsePoints(data["points"])
        let chunkCount = decodeInt64(data["chunkCount"]).map { max(0, Int($0)) }
        return makeDownloadedRide(docId: docId, data: data, points: points, chunkCount: chunkCount)
    }

    /// Builds the same ride metadata as the legacy array parser, but with
    /// points reassembled by the sync layer from the `points/{chunk}` children.
    /// Keeping this conversion here means SwiftData and every post-download
    /// consumer still receive one flat ride, regardless of cloud shape.
    static func parseRideDocument(
        docId: String,
        data: [String: Any],
        points: [DownloadedPoint],
        chunkCount: Int
    ) -> DownloadedRide? {
        makeDownloadedRide(
            docId: docId,
            data: data,
            points: points,
            chunkCount: max(0, chunkCount)
        )
    }

    static func parsePoints(_ value: Any?) -> [DownloadedPoint] {
        parseFirestorePoints(value)
    }

    private static func makeDownloadedRide(
        docId: String,
        data: [String: Any],
        points: [DownloadedPoint],
        chunkCount: Int?
    ) -> DownloadedRide? {
        guard let start = decodeDate(data["startTime"]) else { return nil }
        let end = decodeDate(data["endTime"])
        let localId = (data["id"] as? String).flatMap(UUID.init(uuidString:))
            ?? UUID(uuidString: docId)
            ?? UUID()
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
            startZoneId: data["startZoneId"] as? String,
            points: points,
            distanceMeters: decodeDouble(data["distance"]),
            movingDurationMillis: movingDurationMillis,
            maxSpeedMps: decodeDouble(data["maxSpeed"]),
            avgSpeedMps: decodeDouble(data["avgSpeed"]),
            pointCount: decodeInt64(data["pointCount"]).map(Int.init),
            chunkCount: chunkCount
        )
    }
}
