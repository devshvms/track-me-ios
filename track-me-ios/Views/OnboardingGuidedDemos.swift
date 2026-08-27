import SwiftUI

struct RideOnboardingDemo: View {
    @Binding var selectedPersona: RidePersona
    let onCompleted: () -> Void

    @State private var launchState = RideStartLaunchState()
    @State private var isLiveShareStarting = false
    @State private var isPaused = false
    @ObservedObject private var unitSettings = UnitSettings.shared

    private var instructions: [String] {
        [
            "Drag to choose how you're moving.",
            "Open live sharing and start a demo session.",
            "Open live sharing and try Copy link.",
            "Slide left to stop the demo ride."
        ].map { LocalizationHelper.localized($0) }
    }

    var body: some View {
        OnboardingDemoHost(instructions: instructions, onCompleted: onCompleted) { step, advance in
            stepContent(step, advance: advance)
        }
    }

    @ViewBuilder
    private func stepContent(_ step: Int, advance: @escaping () -> Void) -> some View {
        switch step {
        case 0:
            RadialStartTrackingControl(
                launchState: $launchState,
                onCommit: { persona in
                    selectedPersona = persona
                    advance()
                }
            )

        case 1:
            demoShareControl(
                isActive: false,
                isStarting: isLiveShareStarting,
                onStart: {
                    isLiveShareStarting = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        isLiveShareStarting = false
                        advance()
                    }
                },
                onCopy: {}
            )

        case 2:
            demoShareControl(
                isActive: true,
                isStarting: false,
                onStart: {},
                onCopy: {
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("In a real ride, Copy link would copy its private live-sharing URL."),
                        style: .info
                    )
                    advance()
                }
            )

        default:
            let speedMps = OnboardingDemoFixture.averageSpeedMetersPerSecond
            ActiveRideHUD(
                trackingState: isPaused ? .paused : .tracking,
                persona: selectedPersona,
                isAutoPaused: false,
                isLiveSharing: true,
                isLiveShareStarting: false,
                isLiveShareAuthenticated: true,
                isOffline: false,
                duration: demoDuration(OnboardingDemoFixture.duration),
                elapsedDuration: demoDuration(OnboardingDemoFixture.duration),
                speedLabel: LocalizationHelper.localized("Speed"),
                speedValue: demoSpeedValue(speedMps, unit: unitSettings.unit),
                speedUnit: UnitFormatter.speedUnitLabel(unitSettings.unit),
                speedAccessibilityValue: UnitFormatter.speed(mps: speedMps, unit: unitSettings.unit),
                distanceValue: UnitFormatter.distanceValue(
                    meters: OnboardingDemoFixture.distanceMeters,
                    unit: unitSettings.unit
                ),
                distanceUnit: UnitFormatter.distanceUnitLabel(unitSettings.unit),
                distanceAccessibilityValue: UnitFormatter.distance(
                    meters: OnboardingDemoFixture.distanceMeters,
                    unit: unitSettings.unit
                ),
                onPauseToggle: { isPaused.toggle() },
                onStop: advance,
                onStartShare: {},
                onStopShare: {},
                onShareLink: { showNoExternalActionToast() },
                onCopyLink: {
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("In a real ride, Copy link would copy its private live-sharing URL."),
                        style: .info
                    )
                },
                onShareAuthRequired: {}
            )
        }
    }

    private func demoShareControl(
        isActive: Bool,
        isStarting: Bool,
        onStart: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
            LiveShareActionDrawer(
                isActive: isActive,
                isStarting: isStarting,
                isAuthenticated: true,
                onStart: onStart,
                onStop: {},
                onShare: { showNoExternalActionToast() },
                onCopy: onCopy,
                onAuthRequired: {}
            )
        }
        .frame(height: 170)
    }
}

struct HistoryOnboardingDemo: View {
    @Binding var selectedPersona: RidePersona
    let onCompleted: () -> Void

    @State private var ride: Ride
    @State private var scrubIndex = 0.0
    @State private var showExport = false
    @State private var previewImage: UIImage?

    init(selectedPersona: Binding<RidePersona>, onCompleted: @escaping () -> Void) {
        _selectedPersona = selectedPersona
        self.onCompleted = onCompleted
        let fixture = OnboardingDemoFixture.makeRide(
            title: LocalizationHelper.localized("Sample ride")
        )
        fixture.persona = selectedPersona.wrappedValue.rawValue
        _ride = State(initialValue: fixture)
    }

    private var instructions: [String] {
        [
            "Open the sample ride.",
            "Scrub the route to inspect speed and elevation.",
            "Scroll down and tap Share.",
            "Customize the export, then save the demo."
        ].map { LocalizationHelper.localized($0) }
    }

    var body: some View {
        OnboardingDemoHost(
            instructions: instructions,
            onCompleted: {
                showExport = false
                onCompleted()
            }
        ) { step, advance in
            stepContent(step, advance: advance)
        }
        .onChange(of: selectedPersona) { _, persona in
            ride.persona = persona.rawValue
        }
    }

    @ViewBuilder
    private func stepContent(_ step: Int, advance: @escaping () -> Void) -> some View {
        switch step {
        case 0:
            Button(action: advance) {
                CompactRideRowView(ride: ride)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint(LocalizationHelper.localized("Shows ride details"))

        case 1:
            VStack(spacing: 10) {
                DemoRoutePreview(
                    points: ride.points ?? [],
                    scrubIndex: Int(scrubIndex.rounded())
                )
                .frame(height: 145)

                CombinedMetricLineChart(
                    points: ride.points ?? [],
                    scrubIndex: Int(scrubIndex.rounded())
                )

                Slider(
                    value: Binding(
                        get: { scrubIndex },
                        set: { value in
                            scrubIndex = value
                            if OnboardingDemoProgress.isMeaningfulScrub(
                                startIndex: 0,
                                currentIndex: Int(value.rounded()),
                                pointCount: ride.points?.count ?? 0
                            ) {
                                advance()
                            }
                        }
                    ),
                    in: 0...Double(max(1, (ride.points?.count ?? 1) - 1)),
                    step: 1
                )
                .accessibilityLabel(LocalizationHelper.localized("Route position"))
            }

        case 2:
            ScrollView {
                VStack(spacing: 14) {
                    DemoRoutePreview(
                        points: ride.points ?? [],
                        scrubIndex: Int(scrubIndex.rounded())
                    )
                    .frame(height: 170)

                    CombinedMetricLineChart(
                        points: ride.points ?? [],
                        scrubIndex: Int(scrubIndex.rounded())
                    )

                    Spacer(minLength: 72)

                    Button(action: advance) {
                        Label(LocalizationHelper.localized("Share"), systemImage: "square.and.arrow.up")
                            .font(BrandTypography.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.primaryFill)
                }
            }
            .frame(height: 340)

        default:
            VStack(spacing: 12) {
                DemoRoutePreview(
                    points: ride.points ?? [],
                    scrubIndex: Int(scrubIndex.rounded())
                )
                .frame(height: 180)

                Button {
                    previewImage = renderRoutePreview()
                    if previewImage != nil {
                        showExport = true
                    }
                } label: {
                    Text(LocalizationHelper.localized("Customize export"))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
            }
            .sheet(isPresented: $showExport) {
                if let previewImage {
                    NavigationStack {
                        ExportPreviewView(
                            ride: ride,
                            snapshotImage: previewImage,
                            demoMode: true,
                            onDemoSave: {
                                showExport = false
                                showNoExternalActionToast()
                                advance()
                            }
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalizationHelper.localized("Close")) {
                                    showExport = false
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func renderRoutePreview() -> UIImage? {
        let size = CGSize(width: 800, height: 800)
        let renderer = ImageRenderer(content: RoutePreviewThumbnail(
            points: ride.points ?? [],
            size: size,
            scrubIndex: nil
        ))
        renderer.scale = 1
        return renderer.uiImage
    }
}

private struct DemoRoutePreview: View {
    let points: [GPSPoint]
    let scrubIndex: Int

    var body: some View {
        GeometryReader { proxy in
            RoutePreviewThumbnail(
                points: points,
                size: proxy.size,
                scrubIndex: scrubIndex
            )
        }
        .accessibilityHidden(true)
    }
}

private func demoDuration(_ seconds: TimeInterval) -> String {
    let wholeSeconds = max(0, Int(seconds))
    return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
}

private func demoSpeedValue(_ metersPerSecond: Double, unit: UnitSystem) -> String {
    let converted = metersPerSecond * (unit == .imperial ? 2.236936 : 3.6)
    return String(format: "%.1f", locale: Locale.current, converted)
}

private func showNoExternalActionToast() {
    ToastManager.shared.show(
        message: LocalizationHelper.localized("Demo only — nothing was shared or saved."),
        style: .info
    )
}
