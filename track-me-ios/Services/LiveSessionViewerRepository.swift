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

struct ViewerNetworkReconnectionState: Equatable {
    let shouldFetchImmediately: Bool
    let resetConsecutiveErrors: Bool
    let showOfflineToast: Bool
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
            Self.cacheSnapshot(sessionId: cleanId, snapshot: snapshot)
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

    // MARK: - In-Memory Snapshot Cache (CIE-035)

    private static var snapshotCache: [String: LiveSessionSnapshot] = [:]
    private static let cacheLock = NSLock()

    static func getCachedSnapshot(sessionId: String) -> LiveSessionSnapshot? {
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return snapshotCache[clean]
    }

    static func cacheSnapshot(sessionId: String, snapshot: LiveSessionSnapshot) {
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        snapshotCache[clean] = snapshot
    }

    static func clearCachedSnapshot(sessionId: String) {
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        snapshotCache.removeValue(forKey: clean)
    }

    static func clearAllCachedSnapshots() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        snapshotCache.removeAll()
    }

    func getCachedSnapshot(sessionId: String) -> LiveSessionSnapshot? {
        Self.getCachedSnapshot(sessionId: sessionId)
    }

    /**
     * CIE-035: Evaluates camera movement necessity considering follow mode and initial centering.
     */
    static func evaluateViewportPreservation(
        isFollowingRider: Bool,
        lastCoordinate: CLLocationCoordinate2D?,
        newCoordinate: CLLocationCoordinate2D?,
        hasCenteredInitially: Bool
    ) -> Bool {
        guard let newCoordinate else { return false }
        if !isFollowingRider && hasCenteredInitially { return false }
        return !hasCenteredInitially || shouldAnimateCamera(from: lastCoordinate, to: newCoordinate)
    }

    /**
     * CIE-036: Evaluates whether camera and UI transitions should be animated based on reduced motion accessibility preference.
     * When reduced motion is preferred, transitions snap immediately to prevent motion sickness and vestibular discomfort.
     */
    static func shouldAnimateTransition(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /**
     * CIE-037: Sanitize and clamp battery level to 0-100%, rejecting negative simulator fallbacks (-1) and out-of-bounds values.
     */
    static func clampBatteryLevel(_ battery: Int?) -> Int? {
        guard let battery = battery, battery >= 0, battery <= 100 else {
            return nil
        }
        return max(0, min(100, battery))
    }

    /**
     * CIE-037: Evaluates whether an auditory/VoiceOver announcement should be made for low battery.
     * Throttles announcements to prevent auditory spam:
     * - Fires when first transitioning into low battery (<= 15%).
     * - Fires when battery drops to critical level (<= 5%) from a higher level.
     * - Suppresses redundant announcements on intermediate 1% drops (e.g. 14%, 13%, 12%).
     */
    static func shouldAnnounceLowBattery(previousBattery: Int?, newBattery: Int?) -> Bool {
        guard let curr = clampBatteryLevel(newBattery) else { return false }
        let prev = clampBatteryLevel(previousBattery)

        // 1. Initial warning when dipping into low battery (<= 15%)
        if curr <= 15 && (prev == nil || prev! > 15) {
            return true
        }

        // 2. Critical warning when dipping into <= 5%
        if curr <= 5, let p = prev, p > 5 {
            return true
        }

        return false
    }

    /**
     * CIE-037: Computes adaptive polling interval for the live viewer.
     * When the rider is in power-save mode (or battery <= 15%), broadcaster pushes occur at ~15s cadence.
     * Adapting the viewer polling interval to 12s avoids burning ~66% unnecessary Redis queries on the $0/mo free tier.
     */
    static func computeViewerAdaptivePollSeconds(
        powerSaveMode: Bool,
        batteryLevel: Int?,
        basePollSeconds: Double = 5.0
    ) -> Double {
        let clampedBat = clampBatteryLevel(batteryLevel)
        let isEffectivePowerSave = powerSaveMode || (clampedBat != nil && clampedBat! <= 15)
        return isEffectivePowerSave ? 12.0 : basePollSeconds
    }

    /**
     * CIE-037: Formats user-facing disclosure when updates arrive at relaxed interval due to power saving.
     */
    static func formatPowerSaveCadenceNotice(powerSaveMode: Bool, batteryLevel: Int?) -> String? {
        let clampedBat = clampBatteryLevel(batteryLevel)
        let isEffectivePowerSave = powerSaveMode || (clampedBat != nil && clampedBat! <= 15)
        guard isEffectivePowerSave else { return nil }
        return LocalizationHelper.localized("Power save active · Location updates every ~15s")
    }

    struct SpectatorThrottleEvaluation: Equatable {
        let isInactive: Bool
        let isThrottled: Bool
        let pollDelaySeconds: Double
        let shouldAnimateMap: Bool
        let noticeText: String?
    }

    /**
     * CIE-044: Evaluates spectator idle inactivity and render throttling state across Web & Mobile.
     *
     * Rules:
     * 1. If trip has ended, disable animations and return base delay with no notice.
     * 2. If app is in the background or obscured (isBackground=true):
     *    - Throttled = true, shouldAnimateMap = false (prevent useless GPU/view repaints while invisible).
     *    - pollDelaySeconds = 30.0s.
     * 3. If spectator has not interacted for >= inactivityThresholdSeconds (default: 300.0s / 5 min):
     *    - isInactive = true, isThrottled = true.
     *    - pollDelaySeconds = 15.0s (relaxed from 5.0s, saving 66% network/CPU).
     *    - shouldAnimateMap = false (avoid battery-draining continuous pan/rotate animation).
     *    - noticeText = LocalizationHelper.localized("Viewer idle · Updates slowed to save battery").
     * 4. If rider is in power-save mode or low battery (<= 15%):
     *    - isThrottled = true, pollDelaySeconds = 12.0s.
     *    - shouldAnimateMap = true.
     *    - noticeText = LocalizationHelper.localized("Power save active · Location updates every ~15s").
     * 5. Active foreground with recent interaction:
     *    - isInactive = false, isThrottled = false, pollDelaySeconds = basePollSeconds (5.0s), shouldAnimateMap = true.
     */
    static func evaluateSpectatorThrottleState(
        isTripEnded: Bool,
        isBackground: Bool = false,
        lastInteractionDate: Date? = nil,
        now: Date = Date(),
        riderPowerSave: Bool = false,
        riderBatteryLevel: Int? = nil,
        basePollSeconds: Double = 5.0,
        inactivityThresholdSeconds: Double = 300.0 // 5 minutes
    ) -> SpectatorThrottleEvaluation {
        if isTripEnded {
            return SpectatorThrottleEvaluation(
                isInactive: false,
                isThrottled: false,
                pollDelaySeconds: basePollSeconds,
                shouldAnimateMap: false,
                noticeText: nil
            )
        }

        if isBackground {
            return SpectatorThrottleEvaluation(
                isInactive: false,
                isThrottled: true,
                pollDelaySeconds: 30.0,
                shouldAnimateMap: false,
                noticeText: nil
            )
        }

        let elapsed = lastInteractionDate != nil
            ? max(0.0, now.timeIntervalSince(lastInteractionDate!))
            : 0.0

        let isInactive = lastInteractionDate != nil && elapsed >= inactivityThresholdSeconds

        if isInactive {
            return SpectatorThrottleEvaluation(
                isInactive: true,
                isThrottled: true,
                pollDelaySeconds: 15.0,
                shouldAnimateMap: false,
                noticeText: LocalizationHelper.localized("Viewer idle · Updates slowed to save battery")
            )
        }

        let clampedBat = clampBatteryLevel(riderBatteryLevel)
        let isEffectivePowerSave = riderPowerSave || (clampedBat != nil && clampedBat! <= 15)
        if isEffectivePowerSave {
            return SpectatorThrottleEvaluation(
                isInactive: false,
                isThrottled: true,
                pollDelaySeconds: 12.0,
                shouldAnimateMap: true,
                noticeText: LocalizationHelper.localized("Power save active · Location updates every ~15s")
            )
        }

        return SpectatorThrottleEvaluation(
            isInactive: false,
            isThrottled: false,
            pollDelaySeconds: basePollSeconds,
            shouldAnimateMap: true,
            noticeText: nil
        )
    }

    // MARK: - CIE-045: Low-Data Mode & Breadcrumb Decimation Telemetry

    public struct DecimationMetrics: Equatable {
        public let pointsPreDecimation: Int
        public let pointsPostDecimation: Int
        public let pointsSaved: Int
        public let decimationRatio: Double
        public let estimatedBytesSaved: Int

        public init(
            pointsPreDecimation: Int,
            pointsPostDecimation: Int,
            pointsSaved: Int,
            decimationRatio: Double,
            estimatedBytesSaved: Int
        ) {
            self.pointsPreDecimation = pointsPreDecimation
            self.pointsPostDecimation = pointsPostDecimation
            self.pointsSaved = pointsSaved
            self.decimationRatio = decimationRatio
            self.estimatedBytesSaved = estimatedBytesSaved
        }
    }

    /**
     * CIE-045: Computes polling delay under Low-Data Mode.
     * When Low-Data Mode is enabled, polling slows to 30.0s to conserve cellular data.
     */
    static func computeLowDataPollDelay(isLowDataMode: Bool, defaultDelaySeconds: TimeInterval = 5.0) -> TimeInterval {
        isLowDataMode ? 30.0 : max(1.0, defaultDelaySeconds)
    }

    /**
     * CIE-045: Computes decimation metrics comparing raw points to decimated stored points.
     * Standard JSON format for coordinate pair `[lat, lng]` consumes ~28 bytes.
     */
    static func computeDecimationMetrics(preCount: Int, postCount: Int) -> DecimationMetrics {
        let safePre = max(0, preCount)
        let safePost = max(0, postCount)
        let pointsSaved = max(0, safePre - safePost)
        let decimationRatio = safePre > 0 ? Double(pointsSaved) / Double(safePre) : 0.0
        let estimatedBytesSaved = pointsSaved * 28

        return DecimationMetrics(
            pointsPreDecimation: safePre,
            pointsPostDecimation: safePost,
            pointsSaved: pointsSaved,
            decimationRatio: decimationRatio,
            estimatedBytesSaved: estimatedBytesSaved
        )
    }

    /**
     * CIE-045: Builds a sanitized, non-PII telemetry payload for low-data mode and decimation.
     * Strictly adheres to privacy invariants: zero raw coordinates, session tokens, or personal info.
     */
    static func buildLowDataTelemetryPayload(
        isLowDataMode: Bool,
        preCount: Int = 0,
        postCount: Int = 0
    ) -> [String: Any] {
        let metrics = computeDecimationMetrics(preCount: preCount, postCount: postCount)
        let roundedRatio = (metrics.decimationRatio * 1000.0).rounded() / 1000.0
        return [
            "low_data_mode": isLowDataMode,
            "points_pre_decimation": metrics.pointsPreDecimation,
            "points_post_decimation": metrics.pointsPostDecimation,
            "points_saved": metrics.pointsSaved,
            "decimation_ratio": roundedRatio,
            "estimated_bytes_saved": metrics.estimatedBytesSaved
        ]
    }

    /**
     * CIE-045: Formats user-facing status notice when low-data mode is active.
     */
    static func formatLowDataNoticeText(isLowDataMode: Bool) -> String? {
        guard isLowDataMode else { return nil }
        return LocalizationHelper.localized("Low-data mode active · Polling every 30s")
    }

    /**
     * CIE-038: Evaluates whether a polyline should be decimated based on point count.
     * Short trips (<= minPointsThreshold, default 200) skip decimation to conserve cycles.
     */
    static func shouldDecimatePolyline(pointCount: Int, minPointsThreshold: Int = 200) -> Bool {
        pointCount > minPointsThreshold
    }

    /**
     * CIE-038: Calculates perpendicular distance in meters from point P to line segment AB.
     * Uses equirectangular local flat projection relative to point A for maximum performance.
     */
    static func computePerpendicularDistanceMeters(
        point: CLLocationCoordinate2D,
        segA: CLLocationCoordinate2D,
        segB: CLLocationCoordinate2D
    ) -> Double {
        let latRad = segA.latitude * .pi / 180.0
        let cosLat = cos(latRad)
        let mPerDegLat = 111320.0
        let mPerDegLng = 111320.0 * cosLat

        let dxAB = (segB.longitude - segA.longitude) * mPerDegLng
        let dyAB = (segB.latitude - segA.latitude) * mPerDegLat

        let dxAP = (point.longitude - segA.longitude) * mPerDegLng
        let dyAP = (point.latitude - segA.latitude) * mPerDegLat

        let segmentLenSq = dxAB * dxAB + dyAB * dyAB
        if segmentLenSq == 0 {
            return sqrt(dxAP * dxAP + dyAP * dyAP)
        }

        let crossProduct = abs(dxAB * dyAP - dyAB * dxAP)
        return crossProduct / sqrt(segmentLenSq)
    }

    /**
     * CIE-038: Ramer-Douglas-Peucker (RDP) polyline decimation for live viewer breadcrumb trails.
     * Prunes collinear micro-jitter points below epsilonMeters (default 3.5m) while strictly
     * preserving start/finish endpoints and sharp corners/turns.
     */
    static func decimateCoordinates(
        coordinates: [CLLocationCoordinate2D],
        epsilonMeters: Double = 3.5,
        minPointsThreshold: Int = 200
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }
        if minPointsThreshold > 0, coordinates.count <= minPointsThreshold {
            return coordinates
        }

        var keepIndices = Set<Int>()
        keepIndices.insert(0)
        keepIndices.insert(coordinates.count - 1)

        func rdp(startIndex: Int, endIndex: Int) {
            var maxDist: Double = 0
            var maxIndex = startIndex
            let first = coordinates[startIndex]
            let last = coordinates[endIndex]

            for i in (startIndex + 1)..<endIndex {
                let dist = computePerpendicularDistanceMeters(point: coordinates[i], segA: first, segB: last)
                if dist > maxDist {
                    maxDist = dist
                    maxIndex = i
                }
            }

            if maxDist > epsilonMeters {
                keepIndices.insert(maxIndex)
                rdp(startIndex: startIndex, endIndex: maxIndex)
                rdp(startIndex: maxIndex, endIndex: endIndex)
            }
        }

        rdp(startIndex: 0, endIndex: coordinates.count - 1)

        return (0..<coordinates.count).compactMap { keepIndices.contains($0) ? coordinates[$0] : nil }
    }

    /**
     * CIE-038: Convenience helper for decimateCoordinates over LiveViewerPoint array.
     */
    static func decimatePoints(
        points: [LiveViewerPoint],
        epsilonMeters: Double = 3.5,
        minPointsThreshold: Int = 200
    ) -> [LiveViewerPoint] {
        guard points.count > 2 else { return points }
        if minPointsThreshold > 0, points.count <= minPointsThreshold {
            return points
        }
        let coords = points.map(\.coordinate)
        let decimatedCoords = decimateCoordinates(coordinates: coords, epsilonMeters: epsilonMeters, minPointsThreshold: minPointsThreshold)
        let decimatedSet = Set(decimatedCoords.map { "\($0.latitude),\($0.longitude)" })
        return points.enumerated().compactMap { index, pt in
            if index == 0 || index == points.count - 1 || decimatedSet.contains("\(pt.lat),\(pt.lng)") {
                return pt
            }
            return nil
        }
    }

    struct ConcludedSummary: Equatable {
        let statusText: String
        let detailsText: String
        let a11yText: String
        let avgSpeedStr: String?
        let durationStr: String
        let distanceStr: String
    }

    /**
     * CIE-039: Calculates total elapsed duration in seconds between two ISO timestamps or dates.
     */
    static func computeElapsedSeconds(startedAt: String?, endedAt: String? = nil, now: Date = Date()) -> Int? {
        guard let start = parseTimestamp(startedAt) else { return nil }
        let end = endedAt.flatMap { parseTimestamp($0) } ?? now
        let diff = Int(end.timeIntervalSince(start))
        return diff >= 0 ? diff : nil
    }

    /**
     * CIE-039: Calculates average speed in km/h or mph for a completed or active trip.
     * Rejects negative distances, non-finite inputs, short durations (< 5 seconds),
     * and supersonic single-hop glitches (> 200 km/h).
     */
    static func computeAverageSpeed(
        distanceMeters: Double,
        durationSeconds: Double,
        useMiles: Bool = false
    ) -> Double? {
        guard distanceMeters.isFinite, distanceMeters >= 0 else { return nil }
        guard durationSeconds.isFinite, durationSeconds >= 5.0 else { return nil }
        if distanceMeters == 0 { return 0.0 }

        let speedKmh = (distanceMeters / 1000.0) / (durationSeconds / 3600.0)
        guard speedKmh.isFinite, speedKmh <= 200.0 else { return nil }

        let speed = useMiles ? speedKmh * 0.621371 : speedKmh
        return (speed * 10.0).rounded() / 10.0
    }

    /**
     * CIE-039: Formats numeric average speed into a localized/unit-aware string ("21.4 km/h" or "13.3 mph").
     */
    static func formatAverageSpeed(averageSpeed: Double?, useMiles: Bool = false) -> String? {
        guard let speed = averageSpeed, speed.isFinite, speed >= 0 else { return nil }
        let unit = useMiles ? "mph" : "km/h"
        return String(format: "%.1f %@", speed, unit)
    }

    /**
     * CIE-039: Constructs a unified summary display and screen-reader accessibility description
     * for a concluded live share session.
     */
    static func formatConcludedSummary(
        stopReason: String?,
        totalDistanceMeters: Double,
        durationSeconds: Double,
        useMiles: Bool = false
    ) -> ConcludedSummary {
        let cleanStop = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedStop = (cleanStop?.isEmpty == false) ? cleanStop! : LocalizationHelper.localized("The rider has ended this live trip.")

        let safeDuration = max(0, durationSeconds)
        let totalMinutes = Int(safeDuration / 60.0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let durationStr: String = {
            if totalMinutes < 1 { return "< 1m" }
            if hours == 0 { return "\(minutes)m" }
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h \(minutes)m"
        }()

        let distanceUnit = useMiles ? "mi" : "km"
        let distanceVal = useMiles ? totalDistanceMeters / 1609.344 : totalDistanceMeters / 1000.0
        let distanceStr = totalDistanceMeters <= 0
            ? (useMiles ? "0.0 mi" : "0.0 km")
            : String(format: "%.1f %@", distanceVal, distanceUnit)

        let avgSpeed = computeAverageSpeed(distanceMeters: totalDistanceMeters, durationSeconds: safeDuration, useMiles: useMiles)
        let avgSpeedStr = formatAverageSpeed(averageSpeed: avgSpeed, useMiles: useMiles)

        var parts: [String] = [resolvedStop]
        parts.append(LocalizationHelper.formatted("Duration: %@", durationStr))
        if totalDistanceMeters > 0 {
            parts.append(LocalizationHelper.formatted("Distance: %@", distanceStr))
        }
        if let avgSpeedStr {
            let avgLabel = LocalizationHelper.localized("Average Speed")
            parts.append("\(avgLabel): \(avgSpeedStr)")
        }

        let detailsText = parts.joined(separator: " · ")
        let a11yAvgPart = avgSpeedStr != nil ? ", \(LocalizationHelper.localized("Average Speed")) \(avgSpeedStr!)" : ""
        let a11yText = "Trip ended. \(resolvedStop) \(LocalizationHelper.formatted("Distance: %@", distanceStr)). \(LocalizationHelper.formatted("Duration: %@", durationStr))\(a11yAvgPart)."

        return ConcludedSummary(
            statusText: LocalizationHelper.localized("ENDED"),
            detailsText: detailsText,
            a11yText: a11yText,
            avgSpeedStr: avgSpeedStr,
            durationStr: durationStr,
            distanceStr: distanceStr
        )
    }

    /**
     * CIE-040: Computes geodesic distance in meters between viewport center and rider coordinate.
     */
    static func computeOffCenterDistanceMeters(
        center: CLLocationCoordinate2D,
        rider: CLLocationCoordinate2D
    ) -> Double {
        computeDistanceMeters(from: center, to: rider)
    }

    /**
     * CIE-040: Formats off-center distance badge string when distance exceeds threshold (default 250m).
     * Returns nil when rider is close to center (< 250m) so button remains clean.
     */
    static func formatOffCenterDistance(
        distanceMeters: Double?,
        useMiles: Bool = false,
        thresholdMeters: Double = 250.0
    ) -> String? {
        guard let dist = distanceMeters, dist.isFinite, dist >= thresholdMeters else {
            return nil
        }
        if useMiles {
            let miles = dist / 1609.344
            return String(format: "%.1f mi", locale: Locale(identifier: "en_US_POSIX"), miles)
        } else {
            let km = dist / 1000.0
            return String(format: "%.1f km", locale: Locale(identifier: "en_US_POSIX"), km)
        }
    }

    /**
     * CIE-040: Formats recenter button label with optional distance badge ("Recenter · 1.4 km").
     */
    static func formatRecenterButtonLabel(
        distanceMeters: Double?,
        useMiles: Bool = false,
        thresholdMeters: Double = 250.0,
        baseLabel: String? = nil
    ) -> String {
        let base = baseLabel ?? LocalizationHelper.localized("Recenter")
        if let distStr = formatOffCenterDistance(distanceMeters: distanceMeters, useMiles: useMiles, thresholdMeters: thresholdMeters) {
            return "\(base) · \(distStr)"
        }
        return base
    }

    /**
     * CIE-040: Formats recenter button accessibility label ("Recenter on rider, 1.4 km away").
     */
    static func formatRecenterAccessibilityLabel(
        distanceMeters: Double?,
        useMiles: Bool = false,
        thresholdMeters: Double = 250.0,
        baseLabel: String? = nil
    ) -> String {
        let base = baseLabel ?? LocalizationHelper.localized("Recenter on rider")
        if let distStr = formatOffCenterDistance(distanceMeters: distanceMeters, useMiles: useMiles, thresholdMeters: thresholdMeters) {
            return "\(base), \(distStr) away"
        }
        return base
    }

    /**
     * CIE-040: Evaluates whether follow mode should automatically resume after inactivity timeout (default 20s).
     * Suppresses auto-resume when trip has ended or when user is currently in follow mode.
     */
    static func shouldResumeFollowMode(
        isFollowing: Bool,
        isEnded: Bool,
        lastInteractionDate: Date?,
        now: Date = Date(),
        timeoutSeconds: TimeInterval = 20.0
    ) -> Bool {
        guard !isFollowing, !isEnded, let lastInteraction = lastInteractionDate else {
            return false
        }
        let elapsed = now.timeIntervalSince(lastInteraction)
        return elapsed >= timeoutSeconds
    }

    // MARK: - CIE-041: Live Share Viewer Session Health Telemetry & Latency Diagnostics

    /**
     * CIE-041: Computes latency in milliseconds between poll start and completion.
     * Clamps negative durations or non-finite intervals to 0.
     */
    static func computePollLatencyMs(startTime: Date, endTime: Date = Date()) -> Int {
        let elapsed = endTime.timeIntervalSince(startTime)
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        return Int((elapsed * 1000.0).rounded())
    }

    /**
     * CIE-041: Evaluates 1% sampling rate gate for viewer health telemetry.
     * Strict $0/month free-tier protection for PostHog event quotas.
     */
    static func shouldSampleViewerHealth(
        sampleRate: Double = 0.01,
        randomValue: Double = Double.random(in: 0.0..<1.0)
    ) -> Bool {
        let clampedRate = max(0.0, min(1.0, sampleRate.isFinite ? sampleRate : 0.01))
        return randomValue < clampedRate
    }

    /**
     * CIE-041: Classifies viewer error codes for telemetry and diagnostics.
     */
    static func classifyViewerError(
        statusCode: Int?,
        errorMessage: String?
    ) -> String {
        if statusCode == 404 || statusCode == 410 {
            return "not_found_or_expired"
        }
        if statusCode == 429 {
            return "rate_limited"
        }
        if let code = statusCode, (500...599).contains(code) {
            return "server_error"
        }
        let msg = (errorMessage ?? "").lowercased()
        if msg.contains("404") || msg.contains("expired") || msg.contains("not found") {
            return "not_found_or_expired"
        }
        if msg.contains("429") || msg.contains("rate limit") {
            return "rate_limited"
        }
        if msg.contains("500") || msg.contains("502") || msg.contains("503") || msg.contains("server error") {
            return "server_error"
        }
        if msg.contains("json") || msg.contains("syntax") || msg.contains("malformed") || msg.contains("invalid response") || msg.contains("decode") || msg.contains("corrupt") {
            return "malformed_response"
        }
        if statusCode == 0 || msg.contains("network") || msg.contains("offline") || msg.contains("internet") || msg.contains("timed out") || msg.contains("connection") || msg.contains("could not connect") || msg.contains("nsurlerrordomain") || msg.contains("-1009") || msg.contains("-1001") || msg.contains("not connected") {
            return "offline_network"
        }
        return "unknown"
    }

    /**
     * CIE-041: Builds sanitized, privacy-safe health telemetry payload without raw coordinates or PII.
     */
    static func buildViewerHealthTelemetryPayload(
        sessionId: String,
        pollLatencyMs: Int,
        statusCode: Int,
        isActive: Bool,
        hasLocation: Bool,
        batteryLevel: Int?,
        pointCount: Int,
        isStale: Bool = false
    ) -> [String: Any] {
        let cleanId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined()
            .prefix(64)
        let clampedLatency = max(0, pollLatencyMs)
        let clampedBattery = batteryLevel.flatMap { clampBatteryLevel($0) }
        let clampedPoints = max(0, pointCount)

        var payload: [String: Any] = [
            "session_id": String(cleanId),
            "sessionId": String(cleanId),
            "poll_latency_ms": clampedLatency,
            "pollLatencyMs": clampedLatency,
            "status_code": statusCode,
            "statusCode": statusCode,
            "is_active": isActive,
            "isActive": isActive,
            "has_location": hasLocation,
            "hasLocation": hasLocation,
            "point_count": clampedPoints,
            "pointCount": clampedPoints,
            "is_stale": isStale,
            "isStale": isStale,
            "platform": "ios"
        ]
        if let bat = clampedBattery {
            payload["battery_level"] = bat
            payload["batteryLevel"] = bat
        }
        return payload
    }

    // MARK: - Reconnection State Memory & Cache Resync (CIE-042)

    public struct ReconnectionResyncEvaluation: Equatable {
        public let shouldFetchImmediately: Bool
        public let shouldUseCachedState: Bool
        public let resetConsecutiveErrors: Bool
        public let statusMessage: String?

        public init(
            shouldFetchImmediately: Bool,
            shouldUseCachedState: Bool,
            resetConsecutiveErrors: Bool,
            statusMessage: String?
        ) {
            self.shouldFetchImmediately = shouldFetchImmediately
            self.shouldUseCachedState = shouldUseCachedState
            self.resetConsecutiveErrors = resetConsecutiveErrors
            self.statusMessage = statusMessage
        }
    }

    /**
     * CIE-042: Evaluates whether map viewport, breadcrumb polyline, and rider marker should be preserved
     * during temporary cellular dropouts. Prevents jarring map resets.
     */
    static func shouldPreserveViewerState(
        hasRenderedLocation: Bool,
        isOffline: Bool
    ) -> Bool {
        hasRenderedLocation
    }

    /**
     * CIE-042: Evaluates offline-to-online reconnection resynchronization logic.
     */
    static func evaluateReconnectionResync(
        isOnline: Bool,
        wasOffline: Bool,
        hasCachedSnapshot: Bool,
        isTripEnded: Bool,
        isFetchInProgress: Bool = false
    ) -> ReconnectionResyncEvaluation {
        if isTripEnded {
            return ReconnectionResyncEvaluation(
                shouldFetchImmediately: false,
                shouldUseCachedState: hasCachedSnapshot,
                resetConsecutiveErrors: false,
                statusMessage: nil
            )
        }

        if !isOnline {
            return ReconnectionResyncEvaluation(
                shouldFetchImmediately: false,
                shouldUseCachedState: hasCachedSnapshot,
                resetConsecutiveErrors: false,
                statusMessage: "Viewer Offline"
            )
        }

        if isOnline && wasOffline {
            return ReconnectionResyncEvaluation(
                shouldFetchImmediately: !isFetchInProgress,
                shouldUseCachedState: hasCachedSnapshot,
                resetConsecutiveErrors: true,
                statusMessage: "Reconnecting..."
            )
        }

        return ReconnectionResyncEvaluation(
            shouldFetchImmediately: false,
            shouldUseCachedState: hasCachedSnapshot,
            resetConsecutiveErrors: false,
            statusMessage: nil
        )
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

    /**
     * CIE-043: Formats localized share text for forwarding a live session.
     */
    static func formatLiveShareMessage(username: String?, shareUrl: URL) -> String {
        let urlStr = shareUrl.absoluteString
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            let format = LocalizationHelper.localized("Track %@'s live ride on TrackMe: %@")
            return String(format: format, username, urlStr)
        } else {
            let format = LocalizationHelper.localized("Track this live ride on TrackMe: %@")
            return String(format: format, urlStr)
        }
    }

    /**
     * CIE-043: Constructs external navigation URL to rider's current coordinate.
     */
    static func buildDirectionsUrl(lat: Double, lng: Double, provider: String = "apple_maps") -> URL? {
        guard lat.isFinite, lng.isFinite, (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lng) else {
            return nil
        }
        if provider == "google_maps" {
            return URL(string: "https://maps.google.com/?daddr=\(lat),\(lng)")
        }
        return URL(string: "https://maps.apple.com/?daddr=\(lat),\(lng)")
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
     * Evaluates network reconnection state transitions for live session viewers (CIE-034).
     *
     * When connection state changes:
     * - If trip has ended or session is missing/expired, suppresses network toasts and polling.
     * - If currently disconnected: shows non-blocking persistent offline toast pill.
     * - If transitioning from disconnected to connected (reconnecting):
     *   triggers immediate location fetch without waiting for delay timer,
     *   and resets consecutive error backoff counter.
     */
    static func evaluateNetworkReconnection(
        isConnected: Bool,
        wasDisconnected: Bool,
        isActive: Bool,
        isExpiredOrMissing: Bool = false
    ) -> ViewerNetworkReconnectionState {
        if !isActive || isExpiredOrMissing {
            return ViewerNetworkReconnectionState(
                shouldFetchImmediately: false,
                resetConsecutiveErrors: false,
                showOfflineToast: false
            )
        }
        let isReconnecting = wasDisconnected && isConnected
        return ViewerNetworkReconnectionState(
            shouldFetchImmediately: isReconnecting,
            resetConsecutiveErrors: isReconnecting,
            showOfflineToast: !isConnected
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
