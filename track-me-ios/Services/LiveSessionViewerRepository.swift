import Foundation
import CoreLocation

struct LiveViewerPoint: Equatable {
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

struct LiveViewerDeadlineStatus: Equatable {
    let isOverdue: Bool
    let deadlineDate: Date
    let timeFormatted: String
    let overdueMinutes: Int
}

struct ViewerForegroundReconnectionState: Equatable {
    let shouldFetchImmediately: Bool
    let resetConsecutiveErrors: Bool
    let clearErrorMessage: Bool
}

struct LiveViewerSpeedStatus: Equatable {
    let isStationary: Bool
    let isStoppedTimerActive: Bool
    let stoppedMinutes: Int
    let displayText: String
    let a11yText: String
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
    let startedAt: String?
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

    func isStaleSignal(now: Date = Date()) -> Bool {
        LiveSessionViewerRepository.isStaleSignal(
            isActive: isActive,
            timestampIso: lastLocation?.timestampIso,
            now: now
        )
    }

    func formatDuration(now: Date = Date()) -> String? {
        LiveSessionViewerRepository.formatDuration(
            startedAtRaw: startedAt,
            endedAtRaw: endedAt,
            now: now
        )
    }

    var totalDistanceMeters: Double {
        LiveSessionViewerRepository.computePathDistanceMeters(path)
    }

    func deadlineStatus(now: Date = Date(), timeFormatter: ((Date) -> String)? = nil) -> LiveViewerDeadlineStatus? {
        LiveSessionViewerRepository.evaluateDeadline(deadlineRaw: deadlineAt, now: now, timeFormatter: timeFormatter)
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

    /**
     * TASK-368 / SCOPE_1.9.3 / CIE-031: Builds a canonical live share URL with optional rider attribution.
     * Appending ?name=... enables rich social link previews on messaging apps (WhatsApp, iMessage, Telegram, etc.).
     */
    static func buildShareUrl(baseURL: String, sessionId: String, riderName: String? = nil) -> URL? {
        let cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSession.isEmpty else { return nil }

        let encodedSession = cleanSession.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanSession
        var urlString = "\(cleanBase)/live/\(encodedSession)"
        if let riderName = riderName?.trimmingCharacters(in: .whitespacesAndNewlines), !riderName.isEmpty {
            if let encodedName = riderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "?name=\(encodedName)"
            }
        }
        return URL(string: urlString)
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
        let startedAt = (root["startedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (root["startedAt"] as? NSNumber).map { "\($0.int64Value)" }
        let destination = (root["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let deadlineAt = (root["deadlineAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (root["deadlineAt"] as? NSNumber).map { "\($0.int64Value)" }
            ?? (root["etaAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (root["etaAt"] as? NSNumber).map { "\($0.int64Value)" }

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
            startedAt: startedAt,
            stopReason: stopReason,
            endReason: endReason,
            endedAt: endedAt,
            destination: destination,
            deadlineAt: deadlineAt,
            lastLocation: parsedLastLocation,
            path: pathPoints
        )
    }

    static let delayedUpdateThresholdSeconds = 45
    static let staleSignalThresholdSeconds = 180

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        if let epochMs = Double(clean), epochMs > 0 {
            let seconds = epochMs > 1_000_000_000_000 ? epochMs / 1000.0 : epochMs
            return Date(timeIntervalSince1970: seconds)
        }
        return parseISO8601Date(clean)
    }

    static func ageSeconds(timestampIso: String?, now: Date = Date()) -> Int? {
        guard let clean = timestampIso?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let parsedDate = parseTimestamp(clean) else {
            return nil
        }
        return max(0, Int(now.timeIntervalSince(parsedDate)))
    }

    static func isDelayedUpdate(powerSaveMode: Bool, timestampIso: String?, now: Date = Date()) -> Bool {
        if powerSaveMode {
            return true
        }
        guard let age = ageSeconds(timestampIso: timestampIso, now: now) else {
            return false
        }
        return age >= delayedUpdateThresholdSeconds
    }

    static func isStaleSignal(isActive: Bool, timestampIso: String?, now: Date = Date(), thresholdSeconds: Int = staleSignalThresholdSeconds) -> Bool {
        guard isActive else { return false }
        guard let age = ageSeconds(timestampIso: timestampIso, now: now) else { return false }
        return age >= thresholdSeconds
    }

    /// Formats the elapsed or total trip duration into a concise string.
    /// Examples:
    /// - < 1 min: "< 1m"
    /// - 45 min: "45m"
    /// - 1 hour 15 min: "1h 15m"
    /// - 2 hours exactly: "2h"
    static func formatDuration(startedAtRaw: String?, endedAtRaw: String? = nil, now: Date = Date()) -> String? {
        guard let startDate = parseTimestamp(startedAtRaw) else { return nil }
        let endDate = parseTimestamp(endedAtRaw) ?? now
        let durationSeconds = max(0, endDate.timeIntervalSince(startDate))
        let totalMinutes = Int(durationSeconds / 60)

        if totalMinutes < 1 {
            return "< 1m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(minutes)m"
        }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func decodeCoordinate(_ value: Any?) -> Double? {
        guard let num = (value as? NSNumber)?.doubleValue, num.isFinite else {
            return nil
        }
        return num
    }

    /// Computes an adaptive, jittered polling delay for Live Share viewers during network errors or server hiccups (CIE-003).
    /// Backs off consecutive errors to avoid stampeding Redis and Vercel serverless ($0/mo cost mandate).
    /// Progression:
    /// - 0 errors: baseDelay (standard 5.0s polling)
    /// - 1 error:  base + 1.0s + jitter (~6.0s - 6.5s)
    /// - 2 errors: base + 3.0s + jitter (~8.0s - 8.5s)
    /// - 3 errors: base + 6.0s + jitter (~11.0s - 11.5s)
    /// - 4+ errors: capped at maxDelay (15.0s)
    static func computeViewerBackoffSeconds(
        consecutiveErrors: Int,
        baseDelay: Double = 5.0,
        maxDelay: Double = 15.0,
        randomProvider: () -> Double = { Double.random(in: 0.0...1.0) }
    ) -> Double {
        if consecutiveErrors <= 0 { return baseDelay }
        let increments: [Double] = [1.0, 3.0, 6.0, 10.0]
        let stepIndex = min(consecutiveErrors - 1, increments.count - 1)
        let step = increments[stepIndex]
        let jitter = randomProvider() * 0.5
        return min(maxDelay, baseDelay + step + jitter)
    }

    static let maxPlausibleJumpMeters: Double = 50_000.0
    static let minAccumulationDisplacementMeters: Double = 2.0

    /// Computes accumulated distance in meters across the session's coordinate trail.
    /// Discards sub-2m stationarity jitter and supersonic single-hop glitches (> 50 km).
    /// Discards Null Island coordinates.
    static func computePathDistanceMeters(_ path: [LiveViewerPoint]) -> Double {
        guard path.count >= 2 else { return 0.0 }
        var totalMeters: Double = 0.0
        var prev: LiveViewerPoint? = nil

        for pt in path {
            guard pt.lat.isFinite, pt.lng.isFinite else { continue }
            guard pt.lat >= -90.0, pt.lat <= 90.0, pt.lng >= -180.0, pt.lng <= 180.0 else { continue }
            if abs(pt.lat) < 0.0001 && abs(pt.lng) < 0.0001 { continue } // Null Island

            if let previous = prev {
                let locPrev = CLLocation(latitude: previous.lat, longitude: previous.lng)
                let locCur = CLLocation(latitude: pt.lat, longitude: pt.lng)
                let dist = locPrev.distance(from: locCur)
                if dist >= minAccumulationDisplacementMeters && dist <= maxPlausibleJumpMeters {
                    totalMeters += dist
                    prev = pt
                }
            } else {
                prev = pt
            }
        }
        return totalMeters
    }

    /// Evaluates scheduled ETA or deadline status (CIE-025).
    /// Formats scheduled time (e.g. "6:30 PM") and calculates whether the trip is overdue.
    static func evaluateDeadline(
        deadlineRaw: String?,
        now: Date = Date(),
        timeFormatter: ((Date) -> String)? = nil
    ) -> LiveViewerDeadlineStatus? {
        guard let raw = deadlineRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let deadlineDate: Date
        if let epochMs = Double(raw), epochMs > 0 {
            deadlineDate = Date(timeIntervalSince1970: epochMs / 1000.0)
        } else if let parsed = parseISO8601Date(raw) {
            deadlineDate = parsed
        } else {
            return nil
        }

        let isOverdue = now > deadlineDate
        let overdueMinutes = isOverdue ? max(0, Int(now.timeIntervalSince(deadlineDate) / 60.0)) : 0
        let timeFormatted: String
        if let customFormatter = timeFormatter {
            timeFormatted = customFormatter(deadlineDate)
        } else {
            let df = DateFormatter()
            df.timeStyle = .short
            df.dateStyle = .none
            timeFormatted = df.string(from: deadlineDate)
        }

        return LiveViewerDeadlineStatus(
            isOverdue: isOverdue,
            deadlineDate: deadlineDate,
            timeFormatted: timeFormatted,
            overdueMinutes: overdueMinutes
        )
    }

    /**
     * Evaluates foreground reconnection transition for active live session viewers (CIE-027).
     *
     * When app returns to foreground:
     * - If trip has ended or session is expired/missing, suppresses polling.
     * - If active, triggers immediate location fetch without waiting for delay timer,
     *   resets consecutive error backoff counter, and clears stale error banner.
     */
    static func evaluateForegroundReconnection(
        isActive: Bool,
        isExpiredOrMissing: Bool
    ) -> ViewerForegroundReconnectionState {
        let shouldFetch = isActive && !isExpiredOrMissing
        return ViewerForegroundReconnectionState(
            shouldFetchImmediately: shouldFetch,
            resetConsecutiveErrors: true,
            clearErrorMessage: true
        )
    }

    /**
     * Calculates the shortest signed angular difference between two compass bearings in degrees.
     * Returns a value in [-180.0, 180.0). Positive indicates clockwise turn, negative indicates counter-clockwise.
     *
     * Prevents 350-degree spin-around jitter when heading crosses the 0°/360° north boundary (CIE-028).
     */
    static func computeShortestArcDelta(from fromAngle: Double, to toAngle: Double) -> Double {
        guard fromAngle.isFinite, toAngle.isFinite else { return 0.0 }
        var c = fromAngle.truncatingRemainder(dividingBy: 360.0)
        if c < 0.0 { c += 360.0 }
        var t = toAngle.truncatingRemainder(dividingBy: 360.0)
        if t < 0.0 { t += 360.0 }
        return ((t - c + 540.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
    }

    /**
     * Calculates continuous rotation angle by applying shortest-arc delta to existing continuous angle.
     * Used for smooth map marker rotation transitions without boundary wrap flips (CIE-028).
     */
    static func computeContinuousAngle(current: Double?, target: Double) -> Double {
        guard target.isFinite else { return current ?? 0.0 }
        guard let currentAngle = current, currentAngle.isFinite else { return target }
        let delta = computeShortestArcDelta(from: currentAngle, to: target)
        return currentAngle + delta
    }

    /**
     * TASK-368 / SCOPE_1.9.3 / CIE-032: Deadband thresholds to throttle camera pans and heading rotations,
     * reducing battery and GPU draw while stationary or experiencing GPS/compass jitter.
     */
    static let cameraDeadbandMeters: Double = 3.0
    static let bearingDeadbandDegrees: Double = 3.0

    static func computeDistanceMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        if from.latitude == to.latitude && from.longitude == to.longitude {
            return 0.0
        }
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }

    static func shouldAnimateCamera(
        from: CLLocationCoordinate2D?,
        to: CLLocationCoordinate2D,
        thresholdMeters: Double = cameraDeadbandMeters
    ) -> Bool {
        guard let from = from else { return true }
        let dist = computeDistanceMeters(from: from, to: to)
        return dist >= thresholdMeters
    }

    static func shouldUpdateBearing(
        currentBearing: Double?,
        targetBearing: Double?,
        isStationary: Bool,
        thresholdDegrees: Double = bearingDeadbandDegrees
    ) -> Bool {
        if isStationary { return false }
        guard let target = targetBearing, target.isFinite else { return false }
        guard let current = currentBearing, current.isFinite else { return true }
        let delta = abs(computeShortestArcDelta(from: current, to: target))
        return delta >= thresholdDegrees
    }

    /// Speed threshold below which rider is treated as stationary (CIE-029).
    static let stationarySpeedThresholdKmh: Double = 3.0

    /**
     * Computes the timestamp from which the rider has been continuously stationary (CIE-029).
     * If speed >= 3.0 km/h, returns nil (clearing stopped state).
     * If stationary:
     * - Returns previousStoppedSinceDate if already stopped.
     * - Otherwise initializes to lastLocationDate (if within 30 min of now) or now.
     */
    static func computeStoppedSinceDate(
        speedKmh: Double?,
        previousStoppedSinceDate: Date?,
        lastLocationDate: Date?,
        now: Date = Date()
    ) -> Date? {
        let isSpeedValid = speedKmh != nil && !(speedKmh!.isNaN || speedKmh!.isInfinite)
        let effectiveSpeed = isSpeedValid ? max(0.0, speedKmh!) : nil
        let isStationary = effectiveSpeed == nil || effectiveSpeed! < stationarySpeedThresholdKmh

        if !isStationary {
            return nil
        }

        if let prev = previousStoppedSinceDate {
            return prev
        }

        if let locDate = lastLocationDate {
            let ageSeconds = now.timeIntervalSince(locDate)
            if ageSeconds >= 0 && ageSeconds <= 1800 { // within 30 min
                return locDate
            }
        }
        return now
    }

    /**
     * Formats duration in seconds into human-readable compact string ("< 1m", "42m", "1h", "1h 15m").
     */
    static func formatDurationSeconds(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        if totalMinutes < 1 {
            return "< 1m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes)m"
        } else if minutes == 0 {
            return "\(hours)h"
        } else {
            return "\(hours)h \(minutes)m"
        }
    }

    /**
     * Evaluates live rider speed vs stationary state and stopped duration (CIE-029).
     * When stationary for >= 60 seconds, displays "Stopped · Xm" instead of "0 km/h".
     */
    static func evaluateSpeedOrStopped(
        speedKmh: Double?,
        stoppedSinceDate: Date?,
        now: Date = Date(),
        useMiles: Bool = false
    ) -> LiveViewerSpeedStatus {
        let isSpeedValid = speedKmh != nil && !(speedKmh!.isNaN || speedKmh!.isInfinite)
        let effectiveSpeed = isSpeedValid ? max(0.0, speedKmh!) : nil
        let isStationary = effectiveSpeed == nil || effectiveSpeed! < stationarySpeedThresholdKmh
        let unit = useMiles ? "mph" : "km/h"

        if !isStationary {
            let rawVal = useMiles ? (effectiveSpeed! * 0.621371) : effectiveSpeed!
            let rounded = Int(rawVal.rounded())
            let text = "\(rounded) \(unit)"
            let a11y = LocalizationHelper.formatted("Rider speed: %@", text)
            return LiveViewerSpeedStatus(
                isStationary: false,
                isStoppedTimerActive: false,
                stoppedMinutes: 0,
                displayText: text,
                a11yText: a11y
            )
        }

        if let stoppedSince = stoppedSinceDate, now >= stoppedSince {
            let stoppedSeconds = now.timeIntervalSince(stoppedSince)
            let stoppedMinutes = Int(stoppedSeconds / 60)
            if stoppedMinutes >= 1 {
                let durationStr = formatDurationSeconds(stoppedSeconds)
                let text = LocalizationHelper.formatted("Stopped · %@", durationStr)
                let a11y = LocalizationHelper.formatted("Rider stopped for %@", durationStr)
                return LiveViewerSpeedStatus(
                    isStationary: true,
                    isStoppedTimerActive: true,
                    stoppedMinutes: stoppedMinutes,
                    displayText: text,
                    a11yText: a11y
                )
            }
        }

        let zeroText = "0 \(unit)"
        let zeroA11y = LocalizationHelper.formatted("Rider speed: %@", zeroText)
        return LiveViewerSpeedStatus(
            isStationary: true,
            isStoppedTimerActive: false,
            stoppedMinutes: 0,
            displayText: zeroText,
            a11yText: zeroA11y
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
