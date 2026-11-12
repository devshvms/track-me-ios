import SwiftUI
import MapKit
import CoreLocation

/// TASK-368 / SCOPE_1.9.3: Native in-app Live Share Viewer.
/// Renders the rider's cyan breadcrumb polyline, green start pin, rotated heading cone, and live stats.
struct LiveSessionViewerView: View {
    let sessionId: String
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @ObservedObject private var unitSettings = UnitSettings.shared

    @State private var repository = LiveSessionViewerRepository()
    @State private var viewerId = "ios_\(UUID().uuidString)"
    @State private var snapshot: LiveSessionSnapshot?
    @State private var isExpiredOrMissing = false
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowingRider = true

    private let liveCyan = Color(red: 6.0 / 255.0, green: 182.0 / 255.0, blue: 212.0 / 255.0)
    private let startGreen = Color(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0)

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
        .task(id: sessionId) {
            await pollSessionLoop()
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 8) {
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
                    let heading = snapshot?.lastLocation?.headingDeg ?? 0
                    Annotation(snapshot?.username ?? LocalizationHelper.localized("TrackMe Rider"), coordinate: current) {
                        HeadingConeMarker(headingDegrees: heading, accentColor: liveCyan)
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
                if !isFollowingRider, let target = currentCoordinate {
                    Button {
                        isFollowingRider = true
                        focusCamera(on: target)
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(liveCyan)
                            .padding(12)
                            .background(.regularMaterial, in: Circle())
                            .shadow(radius: 3)
                    }
                    .padding(14)
                    .accessibilityLabel(LocalizationHelper.localized("Center on my location"))
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
                            ?? LocalizationHelper.localized("This live sharing session has ended or expired.")
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomTelemetryBar: some View {
        let speedText: String = {
            if let mps = snapshot?.lastLocation?.speedMetersPerSecond {
                return UnitFormatter.speed(mps: mps, unit: unitSettings.unit)
            }
            return "—"
        }()

        return HStack(spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.subheadline)
                        .foregroundStyle(liveCyan)
                    Text(speedText)
                        .font(.subheadline.weight(.bold))
                }

                if let battery = snapshot?.lastLocation?.batteryLevel {
                    HStack(spacing: 3) {
                        Image(systemName: snapshot?.lastLocation?.powerSaveMode == true ? "battery.25" : "battery.100")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(battery)%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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

    private func pollSessionLoop() async {
        var tick = 0
        while !Task.isCancelled {
            let result = await repository.fetchSnapshot(sessionId: sessionId)
            switch result {
            case .success(let fetched):
                snapshot = fetched
                isExpiredOrMissing = false
                errorMessage = nil
                isLoading = false
                if isFollowingRider, let coordinate = fetched.lastLocation?.coordinate {
                    focusCamera(on: coordinate)
                }
                if fetched.isActive && tick % 3 == 0 {
                    _ = await repository.sendViewerPing(sessionId: sessionId, viewerId: viewerId)
                }
                if !fetched.isActive {
                    return
                }
            case .notFoundOrExpired:
                isExpiredOrMissing = true
                isLoading = false
                return
            case .error(let msg):
                errorMessage = msg
                isLoading = false
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
