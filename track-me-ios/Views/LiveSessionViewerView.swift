import SwiftUI
import MapKit
import CoreLocation

/// TASK-368 / SCOPE_1.9.3: Native in-app Live Share Viewer.
/// Renders the rider's cyan breadcrumb polyline, green start pin, rotated heading cone, and live stats.
struct LiveSessionViewerView: View {
    let sessionId: String
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var unitSettings = UnitSettings.shared

    @State private var repository = LiveSessionViewerRepository()
    @State private var viewerId = "ios_\(UUID().uuidString)"
    @State private var snapshot: LiveSessionSnapshot?
    @State private var isExpiredOrMissing = false
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowingRider = true
    @State private var hasCenteredInitially = false
    @State private var hasRenderedLocationInitially = false
    @State private var nowDate = Date()
    @State private var refreshTrigger: Int = 0

    private let liveCyan = Color(red: 6.0 / 255.0, green: 182.0 / 255.0, blue: 212.0 / 255.0)
    private let startGreen = Color(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0)
    private let finishRed = Color(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0)

    private struct ViewerPollKey: Equatable {
        let sessionId: String
        let isSceneActive: Bool
        let refreshTrigger: Int
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapSection
                bottomTelemetryBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    headerTitle
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(LocalizationHelper.localized("Close"))
                }
            }
        }
        .task(id: ViewerPollKey(sessionId: sessionId, isSceneActive: scenePhase == .active, refreshTrigger: refreshTrigger)) {
            guard scenePhase == .active else { return }
            if isExpiredOrMissing || snapshot?.isActive == false { return }
            await pollSessionLoop()
        }
    }

    private var headerTitle: some View {
        let lastLoc = snapshot?.lastLocation
        let isStale = snapshot?.isStaleSignal(now: nowDate) == true
        let isDelayed = snapshot?.isActive == true && !isStale && LiveSessionViewerRepository.isDelayedUpdate(
            powerSaveMode: lastLoc?.powerSaveMode == true,
            timestampIso: lastLoc?.timestampIso,
            now: nowDate
        )

        return HStack(spacing: 6) {
            let titleText: String = {
                if let username = snapshot?.username {
                    return LocalizationHelper.formatted("Watching %@", username)
                }
                return LocalizationHelper.localized("Loading live location…")
            }()
            Text(titleText)
                .font(.headline)
                .lineLimit(1)

            if snapshot != nil || isExpiredOrMissing {
                let active = snapshot?.isActive == true
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                    Text(active
                        ? LocalizationHelper.localized("LIVE")
                        : LocalizationHelper.localized("ENDED"))
                        .font(.caption2.weight(.bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (active ? liveCyan.opacity(0.18) : Color(uiColor: .secondarySystemFill)),
                    in: Capsule()
                )
                .foregroundStyle(active ? liveCyan : .secondary)
                .accessibilityElement(children: .combine)
            }

            if isStale {
                Text(LocalizationHelper.localized("Signal paused"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(.red)
                    .accessibilityLabel(LocalizationHelper.localized("GPS signal paused, waiting for rider location"))
            } else if isDelayed {
                Text(LocalizationHelper.localized("Delayed"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                    .accessibilityLabel(LocalizationHelper.localized("Location updates delayed"))
            }
        }
    }

    private var mapSection: some View {
        let coordinates = snapshot?.path.map(\.coordinate) ?? []
        let currentCoordinate = snapshot?.lastLocation?.coordinate

        return ZStack {
            Map(position: $cameraPosition) {
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(liveCyan, lineWidth: 5)
                }

                if let start = coordinates.first {
                    Annotation(LocalizationHelper.localized("Start"), coordinate: start) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 18, height: 18)
                                .shadow(radius: 2)
                            Circle()
                                .fill(startGreen)
                                .frame(width: 12, height: 12)
                        }
                    }
                }

                if let current = currentCoordinate {
                    let isEnded = snapshot?.isActive == false
                    let hasHeading = snapshot?.lastLocation?.headingDeg != nil && !isEnded
                    let title: String = {
                        if isEnded {
                            if let dest = snapshot?.destination?.trimmingCharacters(in: .whitespacesAndNewlines), !dest.isEmpty {
                                return dest
                            }
                            return LocalizationHelper.localized("Destination")
                        }
                        return snapshot?.username ?? LocalizationHelper.localized("TrackMe Rider")
                    }()
                    Annotation(title, coordinate: current) {
                        if isEnded {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 22, height: 22)
                                    .shadow(radius: 2)
                                Circle()
                                    .fill(finishRed)
                                    .frame(width: 16, height: 16)
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        } else if hasHeading, let heading = snapshot?.lastLocation?.headingDeg {
                            HeadingConeMarker(headingDegrees: heading, accentColor: liveCyan)
                        } else {
                            StationaryDotMarker(accentColor: liveCyan)
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in
                    isFollowingRider = false
                }
            )
            .overlay(alignment: .bottomTrailing) {
                if currentCoordinate != nil || coordinates.count >= 2 {
                    VStack(alignment: .trailing, spacing: 8) {
                        if !isFollowingRider, let target = currentCoordinate {
                            Button {
                                isFollowingRider = true
                                focusCamera(on: target)
                            } label: {
                                Label(
                                    LocalizationHelper.localized("Recenter"),
                                    systemImage: "location.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(liveCyan)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(radius: 3)
                            }
                            .accessibilityLabel(LocalizationHelper.localized("Recenter"))
                            .accessibilityHint(LocalizationHelper.localized("Re-center map on rider's current location"))
                        }
                        if coordinates.count >= 2 {
                            Button {
                                isFollowingRider = false
                                fitRouteCamera(coordinates: coordinates)
                            } label: {
                                Label(
                                    LocalizationHelper.localized("Fit route"),
                                    systemImage: "arrow.up.left.and.arrow.down.right"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(radius: 3)
                            }
                            .accessibilityLabel(LocalizationHelper.localized("Fit route"))
                            .accessibilityHint(LocalizationHelper.localized("Fits the entire route trail on the map"))
                        }
                    }
                    .padding(14)
                }
            }

            if isLoading && snapshot == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(LocalizationHelper.localized("Loading live location…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if isExpiredOrMissing || (snapshot != nil && snapshot?.isActive == false) {
                VStack {
                    Text(
                        snapshot?.stopReason
                            ?? snapshot?.endReason
                            ?? (snapshot?.isActive == false
                                ? LocalizationHelper.localized("The rider has ended this live trip.")
                                : LocalizationHelper.localized("This live sharing session has ended or expired."))
                    )
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(12)
                    Spacer()
                }
            } else if let errorMessage, snapshot == nil {
                VStack {
                    Text(errorMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                    Spacer()
                }
            } else if snapshot?.isActive == true && currentCoordinate == nil {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(LocalizationHelper.localized("Session live — waiting for first GPS signal…"))
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    Spacer()
                }
            } else if snapshot?.isStaleSignal(now: nowDate) == true && currentCoordinate != nil {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(LocalizationHelper.localized("Signal paused · Waiting for rider GPS"))
                            .font(.caption.weight(.medium))
                        Button {
                            refreshTrigger += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizationHelper.localized("Retry"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    )
                    .padding(12)
                    Spacer()
                }
            } else if errorMessage != nil {
                VStack {
                    HStack(spacing: 8) {
                        Text(LocalizationHelper.localized("Connection slow — retrying…"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
                        Button {
                            refreshTrigger += 1
                        } label: {
                            Text(LocalizationHelper.localized("Retry"))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizationHelper.localized("Retry"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.92), in: Capsule())
                    .padding(12)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomTelemetryBar: some View {
        let lastLoc = snapshot?.lastLocation
        let speedText: String = {
            if let mps = lastLoc?.speedMetersPerSecond {
                return UnitFormatter.speed(mps: mps, unit: unitSettings.unit)
            }
            return "—"
        }()
        let destinationText = snapshot?.destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDestination = destinationText.map { !$0.isEmpty } ?? false
        let ageSeconds = LiveSessionViewerRepository.ageSeconds(timestampIso: lastLoc?.timestampIso, now: nowDate)

        return VStack(spacing: 8) {
            if hasDestination || ageSeconds != nil {
                HStack(spacing: 8) {
                    if let destinationText, !destinationText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(liveCyan)
                            Text(destinationText)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(LocalizationHelper.formatted("Destination: %@", destinationText))
                    }

                    Spacer(minLength: 8)

                    if let ageSeconds {
                        let ageLabel = ageSeconds < 60 ? "\(ageSeconds)s" : "\(ageSeconds / 60)m"
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(LocalizationHelper.formatted("Updated %@", ageLabel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.subheadline)
                            .foregroundStyle(liveCyan)
                        Text(speedText)
                            .font(.subheadline.weight(.bold))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        lastLoc?.speedMetersPerSecond != nil
                            ? LocalizationHelper.formatted("Rider speed: %@", speedText)
                            : LocalizationHelper.localized("Rider speed unavailable")
                    )

                    if let battery = lastLoc?.batteryLevel {
                        let isLowBattery = battery <= 15
                        let batteryColor: Color = isLowBattery ? .red : .secondary
                        let batteryIconName: String = isLowBattery
                            ? "battery.25"
                            : (lastLoc?.powerSaveMode == true ? "battery.50" : "battery.100")
                        let a11yLabel = isLowBattery
                            ? LocalizationHelper.formatted("Rider battery low: %lld percent", Int64(battery))
                            : LocalizationHelper.formatted("Rider battery: %lld percent", Int64(battery))

                        HStack(spacing: 3) {
                            Image(systemName: batteryIconName)
                                .font(.subheadline)
                                .foregroundStyle(batteryColor)
                            Text("\(battery)%")
                                .font(.subheadline)
                                .fontWeight(isLowBattery ? .semibold : .regular)
                                .foregroundStyle(batteryColor)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(a11yLabel)
                    }

                    if let duration = snapshot?.formatDuration(now: nowDate) {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.subheadline)
                                .foregroundStyle(liveCyan)
                            Text(duration)
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(LocalizationHelper.formatted("Duration: %@", duration))
                    }
                }

                Spacer(minLength: 8)

                Button {
                    if let url = URL(string: "\(APIConfig.baseURL)/live/\(sessionId)") {
                        openURL(url)
                    }
                } label: {
                    Label(
                        LocalizationHelper.localized("Open in browser"),
                        systemImage: "safari"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(LocalizationHelper.localized("Open in browser"))
                .accessibilityHint(LocalizationHelper.localized("Opens this live tracking session in Safari"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func focusCamera(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                )
            )
        }
    }

    private func fitRouteCamera(coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLng = coordinates[0].longitude
        var maxLng = coordinates[0].longitude

        for coord in coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLng = min(minLng, coord.longitude)
            maxLng = max(maxLng, coord.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2.0,
            longitude: (minLng + maxLng) / 2.0
        )
        let latDelta = max(0.004, (maxLat - minLat) * 1.35)
        let lngDelta = max(0.004, (maxLng - minLng) * 1.35)

        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
                )
            )
        }
    }

    private func pollSessionLoop() async {
        TelemetryManager.shared.trackLiveShareViewed(sessionId: sessionId, surface: "in_app_viewer")
        var tick = 0
        var consecutiveErrors = 0
        while !Task.isCancelled {
            nowDate = Date()
            let result = await repository.fetchSnapshot(sessionId: sessionId)
            var nextSleepSeconds: Double = 5.0
            switch result {
            case .success(let fetched):
                consecutiveErrors = 0
                snapshot = fetched
                isExpiredOrMissing = false
                errorMessage = nil
                isLoading = false
                if !hasRenderedLocationInitially, fetched.lastLocation != nil {
                    hasRenderedLocationInitially = true
                    TelemetryManager.shared.trackLiveShareLocationRendered(
                        sessionId: sessionId,
                        pathPoints: fetched.path.count,
                        hasHeading: fetched.lastLocation?.headingDeg != nil,
                        isStopped: !fetched.isActive
                    )
                }
                if let coordinate = fetched.lastLocation?.coordinate,
                   isFollowingRider || !hasCenteredInitially {
                    focusCamera(on: coordinate)
                    hasCenteredInitially = true
                }
                if fetched.isActive && tick % 3 == 0 {
                    _ = await repository.sendViewerPing(sessionId: sessionId, viewerId: viewerId)
                }
                if !fetched.isActive {
                    return
                }
                nextSleepSeconds = 5.0
            case .notFoundOrExpired:
                isExpiredOrMissing = true
                isLoading = false
                return
            case .error(let msg):
                consecutiveErrors += 1
                errorMessage = msg
                isLoading = false
                nextSleepSeconds = LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: consecutiveErrors)
            }
            tick += 1
            let sleepNanos = UInt64(nextSleepSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanos)
        }
    }
}

private struct HeadingConeMarker: View {
    let headingDegrees: Double
    let accentColor: Color

    var body: some View {
        ZStack {
            // Directional translucency cone rotated to rider heading (0 = North, clockwise).
            ConeTriangle()
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.36), accentColor.opacity(0.04)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: 44, height: 38)
                .offset(y: -19)
                .rotationEffect(.degrees(headingDegrees))

            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .shadow(radius: 2)

            Circle()
                .fill(accentColor)
                .frame(width: 16, height: 16)

            Image(systemName: "location.north.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(headingDegrees))
        }
        .frame(width: 72, height: 72)
    }
}

private struct ConeTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct StationaryDotMarker: View {
    let accentColor: Color

    var body: some View {
        ZStack {
            // Subtle translucent pulse ring
            Circle()
                .fill(accentColor.opacity(0.22))
                .frame(width: 32, height: 32)

            // White halo ring
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .shadow(radius: 2)

            // Solid cyan center dot
            Circle()
                .fill(accentColor)
                .frame(width: 16, height: 16)
        }
        .frame(width: 44, height: 44)
    }
}
