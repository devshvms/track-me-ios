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
}

struct DownloadedPoint: Equatable {
    let latitude, longitude, altitude, accuracy, speed: Double
    let timestamp: Date
    let isPaused: Bool
}

extension FirestoreSyncManager {
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
        return DownloadedRide(
            localId: localId, firestoreId: docId, startTime: start, endTime: end,
            sourceInfo: (data["sourceInfo"] as? String) ?? "Cloud Sync",
            title: data["title"] as? String,
            persona: (data["persona"] as? String) ?? "AUTO",
            points: points
        )
    }
}
