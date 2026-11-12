import Foundation
import CoreLocation

struct LiveViewerPoint: Equatable {
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

struct LiveViewerLastLocation: Equatable {
    let lat: Double
    let lng: Double
    /// Speed over the wire from `/api/track/{sessionId}/location` is reported in km/h.
    let speedKmh: Double?
    let headingDeg: Double?
    let batteryLevel: Int?
    let powerSaveMode: Bool
    let timestampIso: String?

    var speedMetersPerSecond: Double? {
        speedKmh.map { max(0, $0) / 3.6 }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

struct LiveSessionSnapshot: Equatable {
    let sessionId: String
    let username: String
    let status: String
    let stopReason: String?
    let endReason: String?
    let endedAt: String?
    let destination: String?
    let deadlineAt: String?
    let lastLocation: LiveViewerLastLocation?
    let path: [LiveViewerPoint]

    var isActive: Bool {
        status.caseInsensitiveCompare("active") == .orderedSame
    }
}

enum LiveSessionFetchResult: Equatable {
    case success(LiveSessionSnapshot)
    case notFoundOrExpired
    case error(String)
}

/// TASK-368: Lightweight client for the anonymous viewer endpoints:
/// - `GET /api/track/{sessionId}/location` (Vercel Edge-cached 2s, public by contract)
/// - `POST /api/track/{sessionId}/ping` (Viewer presence heartbeat so the rider sees `activeViewers`)
final class LiveSessionViewerRepository {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSnapshot(sessionId: String) async -> LiveSessionFetchResult {
        let cleanId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty,
              let url = URL(string: APIConfig.LiveShare.locationPush(sessionId: cleanId)) else {
            return .notFoundOrExpired
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 || code == 410 {
                return .notFoundOrExpired
            }
            guard (200...299).contains(code) else {
                let serverError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                return .error(serverError?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HTTP \(code)")
            }
            guard let snapshot = Self.parseSnapshot(sessionId: cleanId, data: data) else {
                return .error(LocalizationHelper.localized("Invalid response from server"))
            }
            return .success(snapshot)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    @discardableResult
    func sendViewerPing(sessionId: String, viewerId: String) async -> Bool {
        let cleanId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanViewer = viewerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, !cleanViewer.isEmpty,
              let url = URL(string: APIConfig.LiveShare.viewerPing(sessionId: cleanId)) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["viewerId": cleanViewer])

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(code)
        } catch {
            return false
        }
    }

    static func parseSnapshot(sessionId: String, data: Data) -> LiveSessionSnapshot? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let username = (root["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "TrackMe Rider"
        let status = (root["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "active"
        let stopReason = (root["stopReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let endReason = (root["endReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let endedAt = (root["endedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let destination = (root["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let deadlineAt = (root["deadlineAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var parsedLastLocation: LiveViewerLastLocation?
        if let loc = root["lastLocation"] as? [String: Any],
           let lat = decodeCoordinate(loc["lat"]),
           let lng = decodeCoordinate(loc["lng"] ?? loc["lon"]) {
            let rawSpeed = (loc["speed"] as? NSNumber)?.doubleValue
            let speedKmh = rawSpeed.flatMap { $0.isFinite ? $0 : nil }
            let rawHeading = (loc["heading"] as? NSNumber)?.doubleValue
            let headingDeg = rawHeading.flatMap { $0.isFinite ? $0 : nil }
            let batteryLevel = (loc["batteryLevel"] as? NSNumber)?.intValue
            let powerSaveMode = (loc["powerSaveMode"] as? Bool) ?? false
            let timestampIso = (loc["timestamp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            parsedLastLocation = LiveViewerLastLocation(
                lat: lat,
                lng: lng,
                speedKmh: speedKmh,
                headingDeg: headingDeg,
                batteryLevel: batteryLevel,
                powerSaveMode: powerSaveMode,
                timestampIso: timestampIso
            )
        }

        var pathPoints: [LiveViewerPoint] = []
        if let rawPath = root["path"] as? [Any] {
            pathPoints.reserveCapacity(rawPath.count)
            for item in rawPath {
                if let pair = item as? [Any], pair.count >= 2,
                   let lat = decodeCoordinate(pair[0]),
                   let lng = decodeCoordinate(pair[1]) {
                    pathPoints.append(LiveViewerPoint(lat: lat, lng: lng))
                } else if let obj = item as? [String: Any],
                          let lat = decodeCoordinate(obj["lat"]),
                          let lng = decodeCoordinate(obj["lng"] ?? obj["lon"]) {
                    pathPoints.append(LiveViewerPoint(lat: lat, lng: lng))
                }
            }
        }

        if pathPoints.isEmpty, let last = parsedLastLocation {
            pathPoints.append(LiveViewerPoint(lat: last.lat, lng: last.lng))
        }

        return LiveSessionSnapshot(
            sessionId: sessionId,
            username: username,
            status: status,
            stopReason: stopReason,
            endReason: endReason,
            endedAt: endedAt,
            destination: destination,
            deadlineAt: deadlineAt,
            lastLocation: parsedLastLocation,
            path: pathPoints
        )
    }

    private static func decodeCoordinate(_ value: Any?) -> Double? {
        guard let num = (value as? NSNumber)?.doubleValue, num.isFinite else {
            return nil
        }
        return num
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
