import SwiftUI
import MapKit
import FirebaseAuth
import StoreKit
import SwiftData
import MessageUI

struct HomeView: View {
    @Bindable var trackingManager = TrackingManager.shared
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapStyle: TrackMeMapStyle = .standard
    @Namespace private var mapScope

    @Bindable var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var unitSettings = UnitSettings.shared
    @State private var liveSharingManager = LiveSharingManager.shared
    @State private var showLiveShareDialog = false
    // B1: durable one-shot post-ride reveal, surfaced once on Home.
    @Bindable var revealCoordinator = RevealCoordinator.shared
    // B4: system in-app review request (self-gated by ReviewPromptPolicy).
    @Environment(\.requestReview) private var requestReview

    @Query private var emergencySettingsList: [EmergencySettings]
    @Query private var emergencyContacts: [EmergencyContact]

    @State private var showEmergencySetup = false
    @State private var showEmergencyCompose = false
    @State private var emergencyMessageBody = ""
    @State private var showShareSheet = false
    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position, scope: mapScope) {
                UserAnnotation()
                if !trackingManager.points.isEmpty {
                    let coordinates = trackingManager.points.map { $0.coordinate }
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            LinearGradient(
                                colors: [BrandColor.cyanBright, BrandColor.cyanDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .mapStyle(mapStyle.mapKitStyle)
            .mapControls {
                MapUserLocationButton()
            }
            .mapScope(mapScope)
            .ignoresSafeArea(edges: .top)
            .accessibilityLabel(LocalizationHelper.localized("Map"))

            // Top UI (Map Style, GPS Warning & Offline Tracking Shield)
            VStack(spacing: 8) {
                if trackingManager.state == .gpsLost || (trackingManager.state == .tracking && trackingManager.timeSinceLastGps > 10.0) {
                    let seconds = Int(trackingManager.timeSinceLastGps)
                    let timeString = seconds > 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
                    Text(LocalizationHelper.formatted("No GPS signal for %@", timeString))
                        .font(.subheadline.bold())
                        .foregroundColor(BrandColor.onWarning)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(BrandColor.warning)
                        .clipShape(Capsule())
                        .padding(.top, 50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // Announce the loss once; don't re-read the ticking seconds.
                        .accessibilityLabel(LocalizationHelper.localized("GPS signal lost"))
                        .accessibilityAddTraits(.updatesFrequently)
                        .onAppear {
                            AccessibilityNotification.Announcement(
                                LocalizationHelper.localized("GPS signal lost")
                            ).post()
                        }
                }

                if trackingManager.state == .storageLow {
                    Text(LocalizationHelper.localized("Storage almost full — free space to resume"))
                        .font(.subheadline.bold())
                        .foregroundColor(BrandColor.onWarning)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(BrandColor.warning)
                        .clipShape(Capsule())
                        .padding(.top, 50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // Non-tappable: iOS has no public storage-settings deep link,
                        // and opening the app's own settings here would mislead.
                        .accessibilityLabel(LocalizationHelper.localized("Storage almost full. Free space to resume."))
                        .onAppear {
                            AccessibilityNotification.Announcement(
                                LocalizationHelper.localized("Storage almost full. Free space to resume.")
                            ).post()
                        }
                }
                if trackingManager.isAutoPaused && trackingManager.state == .tracking {
                    Text(LocalizationHelper.localized("Auto Paused"))
                        .font(.subheadline.bold()).foregroundColor(.black)
                        .padding(.vertical, 8).padding(.horizontal, 16)
                        .background(BrandColor.warning).clipShape(Capsule())
                        .accessibilityLabel(LocalizationHelper.localized("Auto paused. You stopped moving; recording continues and distance is not counting."))
                }

                if !networkMonitor.isConnected {
                    let shieldText = trackingManager.state != .idle
                        ? "🛡️ Offline Tracking Shield Active • Route Safely Recording"
                        : "🛡️ Offline Tracking Shield • Ready to Record Locally"

                    let shieldA11yLabel = trackingManager.state != .idle
                        ? LocalizationHelper.localized("Offline tracking active. Route is recording locally.")
                        : LocalizationHelper.localized("Offline mode. Rides will record locally.")

                    Text(LocalizationHelper.localized(shieldText))
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(BrandColor.successContainerDark.opacity(0.95))
                        .overlay(
                            Capsule()
                                .stroke(BrandColor.success, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                        .padding(.top, (trackingManager.state == .gpsLost || trackingManager.timeSinceLastGps > 10.0) ? 0 : 50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // VoiceOver reads "🛡️" as "shield" before the sentence; use a clean label.
                        .accessibilityLabel(shieldA11yLabel)
                }

                HStack {
                    MapCompass(scope: mapScope)
                        .padding(.leading, 16)
                        .padding(.top, trackingManager.state == .gpsLost ? 16 : 50)

                    Spacer()

                    VStack(spacing: 16) {
                        MapStyleMenu(selection: $mapStyle) {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 48, height: 48)
                                .background(.regularMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }

                        Button(action: { showLiveShareDialog = true }) {
                            if liveSharingManager.isActive {
                                VStack(spacing: 2) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(formatDuration(TimeInterval(liveSharingManager.remainingSeconds)))
                                        // Fixed-size chrome: clamp the environment below rather than
                                        // scaling this 10pt countdown out of its 48pt touch target.
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                                .background(BrandColor.success.gradient)
                                .clipShape(Circle())
                                .shadow(color: BrandColor.success.opacity(0.5), radius: 6)
                                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                            } else {
                                Image(systemName: "location.viewfinder")
                                    .font(.title2)
                                    .foregroundColor(.primary)
                                    .frame(width: 48, height: 48)
                                    .background(.regularMaterial)
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                        }
                        .accessibilityLabel(liveSharingManager.isActive
                            ? LocalizationHelper.localized("Live sharing active")
                            : LocalizationHelper.localized("Start live location sharing"))
                        .accessibilityValue(liveSharingManager.isActive
                            ? LocalizationHelper.formatted("%@ remaining",
                                formatDuration(TimeInterval(liveSharingManager.remainingSeconds)))
                            : "")
                        .sensoryFeedback(trigger: liveSharingManager.isActive) { _, active in
                            active ? .success : .impact(weight: .light)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.top, trackingManager.state == .gpsLost ? 16 : 50)
                }
                Spacer()
            }

            VStack(spacing: 20) {
                RideStatsCard(
                    isTracking: trackingManager.state != .idle,
                    duration: formatDuration(trackingManager.durationInMillis / 1000),
                    speedValue: UnitFormatter.speed(mps: trackingManager.currentSpeed, unit: unitSettings.unit).split(separator: " ").first.map(String.init) ?? "0.0",
                    speedUnit: UnitFormatter.speedUnitLabel(unitSettings.unit),
                    speedAccessibilityValue: UnitFormatter.speed(mps: trackingManager.currentSpeed, unit: unitSettings.unit),
                    distanceValue: UnitFormatter.distanceValue(meters: trackingManager.totalDistance, unit: unitSettings.unit),
                    distanceUnit: UnitFormatter.distanceUnitLabel(unitSettings.unit),
                    distanceAccessibilityValue: UnitFormatter.distance(meters: trackingManager.totalDistance, unit: unitSettings.unit)
                )

                // SOS Component
                if trackingManager.state != .idle && Auth.auth().currentUser != nil {
                    SwipeToTriggerSlider(onTriggered: {
                        let isSetupComplete = emergencySettingsList.first?.isSetupComplete ?? false
                        if !EmergencySetupLogic.isSetupComplete(isSetupComplete: isSetupComplete, contactCount: emergencyContacts.count) {
                            ToastManager.shared.show(
                                message: LocalizationHelper.localized("Set up emergency contacts to use SOS"),
                                style: .warning
                            )
                            showEmergencySetup = true
                        } else {
                            EmergencyManager.shared.startBroadcast()
                            EmergencyManager.shared.fetchFreshLocation { coordinate in
                                UIDevice.current.isBatteryMonitoringEnabled = true
                                let template = emergencySettingsList.first?.messageTemplate ?? "EMERGENCY! My location: [Location Link]"
                                self.emergencyMessageBody = EmergencyManager.shared.buildEmergencyMessage(
                                    template: template,
                                    coordinate: coordinate ?? trackingManager.points.last?.coordinate,
                                    battery: Float(UIDevice.current.batteryLevel),
                                    deviceModel: UIDevice.current.model,
                                    date: Date()
                                )

                                if MFMessageComposeViewController.canSendText() {
                                    showEmergencyCompose = true
                                } else {
                                    showShareSheet = true
                                }
                            }
                        }
                    })
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Main Action Buttons
                HStack(spacing: 24) {
                    switch trackingManager.state {
                    case .idle:
                        TrackingButton(icon: "play.fill", color: BrandColor.primaryFill,
                                       label: LocalizationHelper.localized("Start tracking")) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                Haptics.impact(.medium)
                                trackingManager.startTracking()
                            }
                        }
                    case .tracking, .gpsLost:
                        TrackingButton(icon: "pause.fill", color: .orange,
                                       label: LocalizationHelper.localized("Pause tracking")) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                Haptics.selection()
                                trackingManager.pauseTracking()
                            }
                        }
                    case .paused, .storageLow:
                        TrackingButton(icon: "play.fill", color: BrandColor.primaryFill,
                                       label: LocalizationHelper.localized("Resume tracking")) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                Haptics.impact(.medium)
                                trackingManager.resumeTracking()
                            }
                        }
                        TrackingButton(icon: "stop.fill", color: .red,
                                       label: LocalizationHelper.localized("Stop tracking")) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                Haptics.impact(.heavy)
                                trackingManager.stopTracking()
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: trackingManager.state)
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showLiveShareDialog) {
            LiveShareDialog()
        }
        .sheet(item: $revealCoordinator.pending, onDismiss: {
            // ANY dismissal — swipe-down (the invited path, we show a drag indicator),
            // interactive, or system — acknowledges the durable one-shot. The "Nice!" button
            // already calls consume(rideId:) below; this runs second there as a harmless
            // idempotent no-op. Mirrors Android's onDismissRequest → consume.
            revealCoordinator.acknowledgeDisplayed()
        }) { reveal in
            PostRideRevealView(reveal: reveal) {
                revealCoordinator.consume(rideId: reveal.rideId)
                // B4: dismissing a good-ride reveal is a peak moment — ask an eligible user to
                // rate. Self-gated; Apple throttles on top. Never after error/SOS/discard.
                Task {
                    let count = await RideStatsStore.shared.current().totalRides
                    if ReviewPrompter.shouldRequestAndRecord(goodRideCount: count) {
                        requestReview()
                    }
                }
            }
        }
        .alert("Location access for safe tracking", isPresented: $trackingManager.showLocationPermissionExplanation) {
            Button("Continue") {
                trackingManager.continueAfterLocationExplanation()
            }
            Button("Not now", role: .cancel) {
                trackingManager.cancelPendingTrackingStart()
            }
        } message: {
            Text("TrackMe records your route locally first and needs location access while you are moving. Allowing Always access lets an active track continue when your phone is locked.")
        }
        .alert("Location access needed", isPresented: $trackingManager.showLocationDeniedRecovery) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Location access is turned off for TrackMe. Turn it on in Settings to record a ride — your route always stays on your device first.")
        }
        .sheet(isPresented: $showEmergencySetup) {
            EmergencySetupView()
        }
        .sheet(isPresented: $showEmergencyCompose) {
            MessageComposeView(
                recipients: emergencyContacts.map { $0.phoneNumber },
                body: emergencyMessageBody,
                onCompletion: { result in
                    EmergencyManager.shared.resolveBroadcast(falseAlarm: result == .cancelled || result == .failed)
                    if result == .sent {
                        ToastManager.shared.show(message: LocalizationHelper.localized("SOS Sent"), style: .success)
                    }
                }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [emergencyMessageBody]) { completed in
                EmergencyManager.shared.resolveBroadcast(falseAlarm: !completed)
            }
        }
        .trackScreen("HomeView")
    }

    private func formatDuration(_ timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

/// The glanceable ride metrics card. Custom sizes stay pixel-identical at the
/// default Dynamic Type size while scaling with larger settings. The visual
/// card is intentionally capped at accessibility3: TIME/SPEED/DISTANCE remain
/// fully exposed through their VoiceOver elements above that visual ceiling.
internal struct RideStatsCard: View {
    let isTracking: Bool
    let duration: String
    let speedValue: String
    let speedUnit: String
    let speedAccessibilityValue: String
    let distanceValue: String
    let distanceUnit: String
    let distanceAccessibilityValue: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        RideStatsCardContent(
            isTracking: isTracking,
            duration: duration,
            speedValue: speedValue,
            speedUnit: speedUnit,
            speedAccessibilityValue: speedAccessibilityValue,
            distanceValue: distanceValue,
            distanceUnit: distanceUnit,
            distanceAccessibilityValue: distanceAccessibilityValue
        )
        // ScaledMetric reads the environment while its view is built. Applying
        // the cap to the content view (rather than after it) keeps AX5 from
        // inflating the visual card before the modifier can clamp it.
        .environment(\.dynamicTypeSize, dynamicTypeSize > .accessibility3 ? .accessibility3 : dynamicTypeSize)
    }
}

private struct RideStatsCardContent: View {
    let isTracking: Bool
    let duration: String
    let speedValue: String
    let speedUnit: String
    let speedAccessibilityValue: String
    let distanceValue: String
    let distanceUnit: String
    let distanceAccessibilityValue: String

    @ScaledMetric(relativeTo: .caption) private var timeLabelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .largeTitle) private var timeValueSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title) private var dividerHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 20) {
            if isTracking {
                VStack(alignment: .center, spacing: 4) {
                    Text("TIME")
                        .font(.system(size: timeLabelSize, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    Text(duration)
                        .font(.system(size: timeValueSize, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LocalizationHelper.localized("Time"))
                .accessibilityValue(duration)

                Divider()
                    .padding(.horizontal, 20)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 40) {
                    RideStatReadout(
                        label: LocalizationHelper.localized("Speed"),
                        value: speedValue,
                        unit: speedUnit,
                        accessibilityValue: speedAccessibilityValue
                    )

                    Divider()
                        .frame(height: dividerHeight)

                    RideStatReadout(
                        label: LocalizationHelper.localized("Distance"),
                        value: distanceValue,
                        unit: distanceUnit,
                        accessibilityValue: distanceAccessibilityValue
                    )
                }

                VStack(spacing: 12) {
                    RideStatReadout(
                        label: LocalizationHelper.localized("Speed"),
                        value: speedValue,
                        unit: speedUnit,
                        accessibilityValue: speedAccessibilityValue
                    )
                    Divider()
                    RideStatReadout(
                        label: LocalizationHelper.localized("Distance"),
                        value: distanceValue,
                        unit: distanceUnit,
                        accessibilityValue: distanceAccessibilityValue
                    )
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 30)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

internal struct RideStatReadout: View {
    let label: String
    let value: String
    let unit: String
    let accessibilityValue: String

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 32

    internal var accessibilityDescriptor: RideStatAccessibilityDescriptor {
        RideStatAccessibilityDescriptor(label: label, value: accessibilityValue)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescriptor.label)
        .accessibilityValue(accessibilityDescriptor.value)
    }
}

/// The semantic contract used by VoiceOver for a single ride metric.
internal struct RideStatAccessibilityDescriptor: Equatable {
    let label: String
    let value: String
}

struct TrackingButton: View {
    var icon: String
    var color: Color
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(color.gradient)
                .clipShape(Circle())
                .shadow(color: color.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .accessibilityLabel(label)
    }
}
