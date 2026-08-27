import SwiftUI
import MapKit
import StoreKit
import FirebaseAuth
import SwiftData

struct HomeView: View {
    var onNavigateHistory: () -> Void = {}
    var onNavigateCommunity: () -> Void = {}
    var scrollToTopRequest: Int = 0

    @Bindable var trackingManager = TrackingManager.shared
    @Bindable private var dashboard = HomeDashboardRepository.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Ride> { !$0.isSynced && !$0.isSample && !$0.pendingDelete })
    private var unsyncedRides: [Ride]
    @State private var position: MapCameraPosition = .region(HomeMapCamera.neutralRegion)
    @State private var mapRegion: MKCoordinateRegion?
    @SceneStorage("home.camera_follow_mode") private var cameraFollowMode = true
    @State private var hasFollowCameraPosition = false
    @State private var mapStyle: TrackMeMapStyle = .standard
    @Namespace private var mapScope

    @Bindable var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var unitSettings = UnitSettings.shared
    @State private var liveSharingManager = LiveSharingManager.shared
    @Bindable private var groupRide = GroupRideManager.shared
    @State private var liveShareSharePayload: LiveShareSharePayload?
    @State private var showGroupSheet = false
    @State private var selectedGroupMember: GroupWire.MemberPosition?
    @State private var explicitGroupMap = false
    @State private var selectedDashboardPersona = DashboardPersonaPreference.selected()
    @State private var dashboardSelectionCameFromPicker = false
    @State private var showDashboardPersonaPicker = false
    @State private var selectedRecentRideId: UUID?
    @State private var didTrackDashboardEntry = false
    @State private var trackedInsightValue: String?
    @State private var groupClockTick = StatusAge.elapsedMillis()
    // B1: durable one-shot post-ride reveal, surfaced once on Home.
    @Bindable var revealCoordinator = RevealCoordinator.shared
    // B4: system in-app review request (self-gated by ReviewPromptPolicy).
    @Environment(\.requestReview) private var requestReview

    @State private var rideStartLaunch = RideStartLaunchState()
    @AppStorage(OnboardingGate.stateKey) private var onboardingStateRaw = OnboardingState.legacy.rawValue
    @AppStorage(OnboardingGate.startHintSeenKey) private var legacyStartHintSeen = false

    private var presentationMode: HomePresentationMode {
        HomePresentationModePolicy.resolve(
            isTrackingIdle: trackingManager.state == .idle,
            explicitGroupMap: explicitGroupMap
        )
    }

    private var isMapInteractive: Bool { presentationMode != .idleDashboard }

    var body: some View {
        NavigationStack {
        ZStack(alignment: .bottom) {
            mapLayer

            HomeMapScrim(mode: presentationMode, reduceMotion: reduceMotion)

            dashboardLayer

            // Top UI (Map Style, GPS Warning & Offline Tracking Shield)
            VStack(spacing: 8) {
                if groupRide.state.isActive && presentationMode != .idleDashboard {
                    let presencePill = groupRide.presencePill(nowElapsedMillis: groupClockTick)
                    GroupPresencePillView(
                        pill: presencePill,
                        onOpenCommunity: { showGroupSheet = true },
                        onClearStatus: { groupRide.clearStatus() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 50)
                    .onChange(of: presencePill, initial: true) { _, current in
                        groupRide.observePresencePill(current, nowElapsedMillis: groupClockTick)
                    }
                }
                if presentationMode == .activeTrackingMap
                    && (trackingManager.state == .gpsLost
                        || (trackingManager.state == .tracking && trackingManager.timeSinceLastGps > 10.0)) {
                    let seconds = Int(trackingManager.timeSinceLastGps)
                    let timeString = seconds > 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
                    Text(LocalizationHelper.formatted("No GPS signal for %@", timeString))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(BrandColor.destructive.opacity(0.94))
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

                if presentationMode == .activeTrackingMap && trackingManager.state == .storageLow {
                    Text(LocalizationHelper.localized("Storage almost full — free space to resume"))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(BrandColor.destructive.opacity(0.94))
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
                if !networkMonitor.isConnected
                    && presentationMode == .activeTrackingMap
                    && !groupRide.state.isActive {
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

                if let notice = groupRide.endNotice {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.slash")
                        Text(groupEndNoticeText(notice))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Button(LocalizationHelper.localized("OK")) {
                            groupRide.acknowledgeEndNotice()
                        }
                        .font(.subheadline.bold())
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }

                if presentationMode == .activeTrackingMap {
                HStack {
                    Spacer()

                    VStack(spacing: 16) {
                        MapStyleMenu(selection: $mapStyle) {
                            Image(systemName: "map")
                                .trackMeMapControlStyle()
                        }

                        Button {
                            Haptics.selection()
                            rearmCameraFollow()
                        } label: {
                            Image(systemName: "location.fill")
                                .trackMeMapControlStyle()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizationHelper.localized("Center on my location"))

                        MapCompass(scope: mapScope)
                            .trackMeMapControlStyle()

                        if groupRide.state.isActive {
                            Button(action: { showGroupSheet = true }) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "person.2.fill")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                        .frame(width: 48, height: 48)
                                        .background(BrandColor.primaryFill.gradient)
                                        .clipShape(Circle())
                                        .shadow(color: BrandColor.primaryFill.opacity(0.5), radius: 6)
                                    Text("\(groupRide.state.memberCount)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(BrandColor.success, in: Circle())
                                }
                            }
                            .accessibilityLabel(LocalizationHelper.localized("Group sharing active"))
                            .accessibilityValue(groupTimeLeftAccessibilityValue)
                        }

                    }
                    .padding(.trailing, 16)
                    .padding(.top, trackingManager.state == .gpsLost ? 16 : 50)
                }
                }
                Spacer()
            }

            if presentationMode == .explicitGroupMap {
                VStack {
                    HStack {
                        Button {
                            explicitGroupMap = false
                        } label: {
                            Label(
                                LocalizationHelper.localized("Dashboard"),
                                systemImage: "chevron.left"
                            )
                            .trackMeMapControlStyle()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(LocalizationHelper.localized("Return to Home dashboard"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 50)
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                if trackingManager.state == .idle {
                    RadialStartTrackingControl(
                        launchState: $rideStartLaunch,
                        preselectedPersona: selectedDashboardPersona,
                        onOpenAllPersonas: { showDashboardPersonaPicker = true }
                    ) { persona in
                        legacyStartHintSeen = true
                        let method = dashboardSelectionCameFromPicker || persona != selectedDashboardPersona
                            ? "persona_picker"
                            : "primary"
                        selectedDashboardPersona = persona
                        TelemetryManager.shared.trackActivityStartCTATapped(
                            persona: persona,
                            method: method
                        )
                        dashboardSelectionCameFromPicker = false
                        trackingManager.startTracking(persona: persona)
                    }
                } else {
                    if RideStartAbortPolicy.canOfferPostCommitUndo(
                        durationInMillis: trackingManager.durationInMillis,
                        distanceMeters: trackingManager.totalDistance
                    ) {
                        Button(role: .destructive) {
                            guard trackingManager.discardNearEmptyRideStart() else { return }
                            Haptics.notify(.warning)
                            TelemetryManager.shared.trackRideStartAborted(method: .postCommitUndo)
                        } label: {
                            Label(LocalizationHelper.localized("Cancel"), systemImage: "xmark")
                                .font(.subheadline.bold())
                        }
                        .buttonStyle(.bordered)
                        .tint(BrandColor.destructive)
                    }

                    ActiveRideHUD(
                        trackingState: trackingManager.state,
                        persona: trackingManager.selectedPersona,
                        isAutoPaused: trackingManager.isAutoPaused,
                        isLiveSharing: liveSharingManager.isActive,
                        isLiveShareStarting: liveSharingManager.isStarting,
                        isLiveShareAuthenticated: Auth.auth().currentUser != nil,
                        isOffline: !networkMonitor.isConnected && !groupRide.state.isActive,
                        duration: formatDuration(trackingManager.durationInMillis / 1000),
                        elapsedDuration: formatDuration(trackingManager.elapsedDurationInMillis / 1000),
                        speedLabel: movementMetric.label,
                        speedValue: movementMetric.value,
                        speedUnit: movementMetric.unit,
                        speedAccessibilityValue: movementMetric.accessibilityValue,
                        distanceValue: UnitFormatter.distanceValue(meters: trackingManager.totalDistance, unit: unitSettings.unit),
                        distanceUnit: UnitFormatter.distanceUnitLabel(unitSettings.unit),
                        distanceAccessibilityValue: UnitFormatter.distance(meters: trackingManager.totalDistance, unit: unitSettings.unit),
                        onPauseToggle: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                if trackingManager.state == .paused || trackingManager.state == .storageLow {
                                    trackingManager.resumeTracking()
                                } else {
                                    trackingManager.pauseTracking()
                                }
                            }
                        },
                        onStop: {
                            trackingManager.stopTracking()
                        },
                        onStartShare: {
                            guard Auth.auth().currentUser != nil else {
                                ToastManager.shared.show(
                                    message: LocalizationHelper.localized("Sign in to share your live location."),
                                    style: .warning
                                )
                                return
                            }
                            guard !groupRide.state.isActive else {
                                ToastManager.shared.show(
                                    message: LocalizationHelper.localized("Solo live sharing is unavailable during a group ride."),
                                    style: .warning
                                )
                                return
                            }
                            liveSharingManager.startSession(durationMinutes: nil)
                        },
                        onStopShare: {
                            liveSharingManager.stopSession()
                            ToastManager.shared.show(
                                message: LocalizationHelper.localized("Live sharing stopped"),
                                style: .info
                            )
                        },
                        onShareLink: {
                            guard let link = liveSharingManager.shareLink,
                                  let url = URL(string: link) else { return }
                            liveShareSharePayload = LiveShareSharePayload(url: url)
                        },
                        onCopyLink: {
                            guard let link = liveSharingManager.shareLink else { return }
                            UIPasteboard.general.string = link
                            ToastManager.shared.show(
                                message: LocalizationHelper.localized("Link copied to clipboard"),
                                style: .success
                            )
                        },
                        onShareAuthRequired: {
                            ToastManager.shared.show(
                                message: LocalizationHelper.localized("Sign in to share your live location."),
                                style: .warning
                            )
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .animation(
                reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3),
                value: presentationMode
            )
        }
        .sheet(item: $liveShareSharePayload) { payload in
            ActivityView(activityItems: [payload.url])
        }
        .sheet(isPresented: $showGroupSheet) {
            CommunityView()
        }
        .sheet(isPresented: $showDashboardPersonaPicker) {
            DashboardPersonaPicker(selectedPersona: selectedDashboardPersona) { persona in
                selectDashboardPersona(persona)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedGroupMember) { member in
            GroupMemberDetailSheet(
                member: member,
                name: groupRide.state.roster.first(where: { $0.uid == member.uid })?.displayName
                    ?? LocalizationHelper.localized("Rider"),
                status: groupStatus(for: member.uid)?.status,
                age: positionAgeBucket(member),
                isFresh: isGroupPositionFresh(member)
            )
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
                // rate. Self-gated; Apple throttles on top. Never after error/discard.
                Task {
                    let count = await RideStatsStore.shared.current().totalRides
                    if ReviewPrompter.shouldRequestAndRecord(goodRideCount: count) {
                        requestReview()
                    }
                }
            }
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
        .navigationDestination(item: $selectedRecentRideId) { rideId in
            if let ride = ride(with: rideId) {
                RideDetailView(ride: ride)
            } else {
                ContentUnavailableView(
                    LocalizationHelper.localized("Activity unavailable"),
                    systemImage: "clock.badge.exclamationmark"
                )
            }
        }
        .toolbar(presentationMode == .activeTrackingMap ? .hidden : .visible, for: .tabBar)
        .trackScreen("HomeView")
        .task(id: groupRide.state.isActive && isMapInteractive) {
            guard groupRide.state.isActive && isMapInteractive else { return }
            while !Task.isCancelled {
                groupClockTick = StatusAge.elapsedMillis()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear {
            rideStartLaunch.reset()
            didTrackDashboardEntry = false
            trackedInsightValue = nil
        }
        .onChange(of: trackingManager.points.count) { _, _ in
            updateFollowCamera()
        }
        .onChange(of: trackingManager.state) { oldState, newState in
            if oldState == .idle && newState != .idle {
                // A new/restored recording begins in follow mode. Once the
                // rider gestures, only the recenter control can re-arm it (§0.1).
                cameraFollowMode = true
                hasFollowCameraPosition = false
                updateFollowCamera()
            } else if oldState != .idle && newState == .idle {
                explicitGroupMap = false
                selectedDashboardPersona = DashboardPersonaPreference.selected()
                dashboardSelectionCameFromPicker = false
                dashboard.invalidate()
            }
        }
        .onChange(of: groupRide.mapFocusRequest) { _, _ in
            explicitGroupMap = true
            focusPendingGroupMember()
        }
        .onChange(of: groupRide.state.isActive) { _, isActive in
            if !isActive { explicitGroupMap = false }
        }
        .onChange(of: dashboard.summary, initial: true) { _, summary in
            dashboard.loadRoutePreview(for: summary?.latestActivity?.localId)
            trackDashboardEntryIfNeeded()
        }
        .onChange(of: presentationMode) { _, _ in
            trackDashboardEntryIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dashboard.refreshOnForeground()
                trackDashboardEntryIfNeeded()
            } else {
                didTrackDashboardEntry = false
                trackedInsightValue = nil
            }
        }
        .onAppear {
            selectedDashboardPersona = DashboardPersonaPreference.selected()
            updateFollowCamera()
            trackDashboardEntryIfNeeded()
        }
    }
    }

    private var mapLayer: some View {
        Map(
            position: $position,
            interactionModes: isMapInteractive ? .all : [],
            scope: mapScope
        ) {
            homeMapContent
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            mapRegion = context.region
        }
        .mapStyle(mapStyle.mapKitStyle)
        .mapScope(mapScope)
        // MapKit's SwiftUI API does not expose a camera-move reason like
        // Maps Compose. These gestures are the public signal available on
        // iOS; programmatic follow/recenter changes do not clear the mode.
        .modifier(InteractiveHomeMapGestures(
            isEnabled: isMapInteractive,
            onGesture: clearCameraFollow
        ))
        // The idle map remains a real, parked backdrop, but its labels must not compete with
        // the dashboard. Apply the blur to the map layer before HomeMapScrim in the parent ZStack.
        .compositingGroup()
        .blur(radius: presentationMode == .idleDashboard ? 14 : 0)
        .ignoresSafeArea(edges: .top)
        .accessibilityLabel(LocalizationHelper.localized("Map"))
        .accessibilityHidden(!isMapInteractive)
    }

    private var dashboardLayer: some View {
        HomeDashboardDeck(
            summary: dashboard.summary,
            isReconciling: dashboard.isReconciling,
            routePoints: dashboard.routePoints,
            groupActive: groupRide.state.isActive,
            groupMemberCount: groupRide.state.memberCount,
            syncNeedsAction: Auth.auth().currentUser != nil
                && !unsyncedRides.isEmpty
                && networkMonitor.isConnected,
            isOffline: !networkMonitor.isConnected,
            isVisible: presentationMode == .idleDashboard,
            onOpenRecent: openRecentActivity,
            onOpenHistory: onNavigateHistory,
            onOpenCommunity: onNavigateCommunity,
            onOpenGroupMap: openExplicitGroupMap,
            scrollToTopRequest: scrollToTopRequest
        )
    }

    @MapContentBuilder
    private var homeMapContent: some MapContent {
        if presentationMode == .activeTrackingMap {
            UserAnnotation()
        }
        if presentationMode == .activeTrackingMap, !trackingManager.points.isEmpty {
            let coordinates = trackingManager.points.map(\.coordinate)
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
        if isMapInteractive {
            ForEach(visibleHeadingTailSegments) { segment in
                MapPolyline(coordinates: [segment.start, segment.end])
                    .stroke(
                        GroupMemberTint.color(index: groupRosterIndex(for: segment.uid))
                            .opacity(segment.opacity),
                        style: StrokeStyle(
                            lineWidth: segment.lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
            ForEach(visibleGroupPositions) { member in
                groupMemberAnnotation(member)
            }
            if let lat = groupRide.state.destinationLat, let lng = groupRide.state.destinationLng {
                Marker(
                    LocalizationHelper.localized("Destination"),
                    systemImage: "flag.checkered",
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
                )
            }
        }
    }

    private func groupMemberAnnotation(_ member: GroupWire.MemberPosition) -> some MapContent {
        let rosterMember = groupRide.state.roster.first(where: { $0.uid == member.uid })
        let label = rosterMember?.displayName ?? LocalizationHelper.localized("Rider")
        let initials = rosterMember?.initials ?? "?"
        let tint = GroupMemberTint.color(index: groupRosterIndex(for: member.uid))
        let stale = isGroupPositionStale(member)
        let age = groupPositionAgeText(member)
        let status = groupStatus(for: member.uid)?.status

        return Annotation(
            label,
            coordinate: CLLocationCoordinate2D(latitude: member.lat, longitude: member.lng)
        ) {
            Button {
                selectedGroupMember = member
            } label: {
                GroupMemberBadge(
                    initials: initials,
                    tint: tint,
                    isStale: stale,
                    ageText: age,
                    status: status
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(groupMarkerAccessibilityLabel(member))
        }
    }

    private func groupRosterIndex(for uid: String) -> Int {
        groupRide.state.roster.firstIndex(where: { $0.uid == uid }) ?? 0
    }

    private func selectDashboardPersona(_ persona: RidePersona) {
        selectedDashboardPersona = persona
        dashboardSelectionCameFromPicker = true
        Haptics.selection()
    }

    private func openRecentActivity(_ recent: HomeRecentActivity) {
        TelemetryManager.shared.trackHomeRecentActivityOpened(persona: recent.persona)
        selectedRecentRideId = recent.localId
    }

    private func openExplicitGroupMap() {
        explicitGroupMap = true
        focusGroupMapOverview()
        TelemetryManager.shared.trackHomeGroupMapOpened()
    }

    private func ride(with id: UUID) -> Ride? {
        var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func trackDashboardEntryIfNeeded() {
        guard scenePhase == .active,
              presentationMode == .idleDashboard,
              let summary = dashboard.summary else { return }
        if !didTrackDashboardEntry {
            didTrackDashboardEntry = true
            TelemetryManager.shared.trackHomeDashboardViewed(historyBucket: summary.historyBucket)
        }
        if let insight = summary.insight,
           trackedInsightValue != insight.analyticsValue {
            trackedInsightValue = insight.analyticsValue
            TelemetryManager.shared.trackHomeInsightShown(insight)
        }
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

    private var movementMetric: RideMovementMetric {
        if trackingManager.selectedPersona == .walk {
            let value = UnitFormatter.paceValue(mps: trackingManager.currentSpeed, unit: unitSettings.unit)
            let accessibilityValue = value == "--"
                ? LocalizationHelper.localized("No current pace")
                : UnitFormatter.pace(mps: trackingManager.currentSpeed, unit: unitSettings.unit)
            return RideMovementMetric(
                label: LocalizationHelper.localized("Pace"),
                value: value,
                unit: UnitFormatter.paceUnitLabel(unitSettings.unit),
                accessibilityValue: accessibilityValue
            )
        }

        return RideMovementMetric(
            label: LocalizationHelper.localized("Speed"),
            value: UnitFormatter.speed(mps: trackingManager.currentSpeed, unit: unitSettings.unit)
                .split(separator: " ").first.map(String.init) ?? "0.0",
            unit: UnitFormatter.speedUnitLabel(unitSettings.unit),
            accessibilityValue: UnitFormatter.speed(mps: trackingManager.currentSpeed, unit: unitSettings.unit)
        )
    }

    private var groupTimeLeftText: String {
        let remaining = max(
            0,
            Date(timeIntervalSince1970: TimeInterval(groupRide.state.expiresAtMillis) / 1000)
                .timeIntervalSinceNow
        )
        return formatDuration(remaining)
    }

    private var groupTimeLeftAccessibilityValue: String {
        guard groupRide.state.hasStarted else {
            return LocalizationHelper.localized("Not started")
        }
        return LocalizationHelper.formatted("%@ remaining", groupTimeLeftText)
    }

    private var defaultFollowSpan: MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    }

    private func clearCameraFollow() {
        cameraFollowMode = false
    }

    private func rearmCameraFollow() {
        cameraFollowMode = true
        hasFollowCameraPosition = false
        guard let coordinate = trackingManager.points.last?.coordinate else {
            position = .userLocation(followsHeading: false, fallback: .automatic)
            return
        }

        // Recenter is the one control allowed to re-arm follow. As on Android,
        // it may choose the deliberate recenter zoom; subsequent follow fixes
        // preserve that span (§0.3 / §1).
        let region = MKCoordinateRegion(center: coordinate, span: defaultFollowSpan)
        mapRegion = region
        position = .region(region)
        hasFollowCameraPosition = true
    }

    private func updateFollowCamera() {
        guard cameraFollowMode,
              trackingManager.state != .idle,
              let coordinate = trackingManager.points.last?.coordinate else { return }

        let span = hasFollowCameraPosition ? (mapRegion?.span ?? defaultFollowSpan) : defaultFollowSpan
        let region = MKCoordinateRegion(center: coordinate, span: span)
        position = .region(region)
        mapRegion = region
        hasFollowCameraPosition = true
    }

    private func focusPendingGroupMember() {
        guard let uid = groupRide.consumeMapFocusUID() else { return }
        guard let member = groupRide.state.positions.first(where: { $0.uid == uid }) else {
            ToastManager.shared.show(
                message: LocalizationHelper.localized("This rider has no current location to show."),
                style: .info
            )
            return
        }

        clearCameraFollow()
        let coordinate = CLLocationCoordinate2D(latitude: member.lat, longitude: member.lng)
        let region = MKCoordinateRegion(center: coordinate, span: mapRegion?.span ?? defaultFollowSpan)
        mapRegion = region
        position = .region(region)
    }

    private func focusGroupMapOverview() {
        var coordinates = groupRide.state.positions.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        }
        if let latitude = groupRide.state.destinationLat,
           let longitude = groupRide.state.destinationLng {
            coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        guard let first = coordinates.first else {
            mapRegion = HomeMapCamera.neutralRegion
            position = .region(HomeMapCamera.neutralRegion)
            return
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minimumLatitude = latitudes.min() ?? first.latitude
        let maximumLatitude = latitudes.max() ?? first.latitude
        let minimumLongitude = longitudes.min() ?? first.longitude
        let maximumLongitude = longitudes.max() ?? first.longitude
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.02, (maximumLatitude - minimumLatitude) * 1.35),
                longitudeDelta: max(0.02, (maximumLongitude - minimumLongitude) * 1.35)
            )
        )
        clearCameraFollow()
        mapRegion = region
        position = .region(region)
    }

    private var visibleHeadingTailSegments: [GroupHeadingTailSegment] {
        let selfUID = Auth.auth().currentUser?.uid
        return groupRide.headingTailSegments(
            nowElapsedMillis: groupClockTick,
            selfUID: selfUID
        )
    }

    private var visibleGroupPositions: [GroupWire.MemberPosition] {
        guard let mapRegion else { return groupRide.state.positions }
        let latitudePadding = mapRegion.span.latitudeDelta * 0.15
        let longitudePadding = mapRegion.span.longitudeDelta * 0.15
        let minLatitude = mapRegion.center.latitude - mapRegion.span.latitudeDelta / 2 - latitudePadding
        let maxLatitude = mapRegion.center.latitude + mapRegion.span.latitudeDelta / 2 + latitudePadding
        let minLongitude = mapRegion.center.longitude - mapRegion.span.longitudeDelta / 2 - longitudePadding
        let maxLongitude = mapRegion.center.longitude + mapRegion.span.longitudeDelta / 2 + longitudePadding
        return groupRide.state.positions.filter {
            $0.lat >= minLatitude && $0.lat <= maxLatitude &&
            $0.lng >= minLongitude && $0.lng <= maxLongitude
        }
    }

    private func isGroupPositionStale(_ position: GroupWire.MemberPosition) -> Bool {
        !isGroupPositionFresh(position)
    }

    private func groupPositionAgeText(_ position: GroupWire.MemberPosition) -> String? {
        guard isGroupPositionStale(position) else { return nil }
        return GroupAgePresentation.text(positionAgeBucket(position), includesAgo: false)
    }

    private func isGroupPositionFresh(_ position: GroupWire.MemberPosition) -> Bool {
        guard let anchor = position.ageAnchor, anchor.isKnown else { return false }
        let age = StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: groupClockTick)
        return age < Int64(max(20, groupRide.state.syncIntervalSec * 2)) * 1_000
    }

    private func positionAgeBucket(_ position: GroupWire.MemberPosition) -> StatusAge.Bucket {
        guard let anchor = position.ageAnchor else { return .unknown }
        return StatusAge.bucket(
            anchor: anchor,
            nowElapsedMillis: groupClockTick,
            syncIntervalSec: groupRide.state.syncIntervalSec
        )
    }

    private func groupStatus(for uid: String) -> GroupWire.MemberStatus? {
        groupRide.state.statuses.first { $0.uid == uid }
    }

    private func groupMarkerAccessibilityLabel(_ member: GroupWire.MemberPosition) -> String {
        let name = groupRide.state.roster.first(where: { $0.uid == member.uid })?.displayName
            ?? LocalizationHelper.localized("Rider")
        var parts = [name]
        if let status = groupStatus(for: member.uid)?.status {
            parts.append(RiderStatusPresentation.label(for: status))
        }
        if let age = GroupAgePresentation.text(positionAgeBucket(member)) {
            parts.append(LocalizationHelper.formatted("Updated %@", age))
        }
        return parts.joined(separator: ", ")
    }

    private func groupEndNoticeText(_ notice: GroupEndNotice) -> String {
        switch notice.reason {
        case .removed:
            return LocalizationHelper.localized("You're no longer in this group.")
        case .expired, .ended:
            return notice.rideStillRecording
                ? LocalizationHelper.localized("This group has ended. Your ride is still recording.")
                : LocalizationHelper.localized("This group has ended.")
        }
    }
}

private enum HomeMapCamera {
    static let neutralRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )
}

private struct HomeMapScrim: View {
    let mode: HomePresentationMode
    let reduceMotion: Bool

    var body: some View {
        LinearGradient(
            colors: mode == .idleDashboard
                ? [.black.opacity(0.72), .black.opacity(0.42)]
                : [.black.opacity(0.28), .black.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.42),
            value: mode
        )
    }
}

private struct InteractiveHomeMapGestures: ViewModifier {
    let isEnabled: Bool
    let onGesture: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1).onChanged { _ in onGesture() }
                )
                .simultaneousGesture(
                    MagnificationGesture().onChanged { _ in onGesture() }
                )
                .simultaneousGesture(
                    RotationGesture().onChanged { _ in onGesture() }
                )
        } else {
            content
        }
    }
}

private struct RideMovementMetric {
    let label: String
    let value: String
    let unit: String
    let accessibilityValue: String
}

private struct TrackMeMapControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.title2)
            .foregroundStyle(.primary)
            .tint(.primary)
            .frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

private extension View {
    func trackMeMapControlStyle() -> some View {
        modifier(TrackMeMapControlModifier())
    }
}

private struct LiveShareSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Compact three-column metrics matching the active Android HUD. The visual
/// card is capped at accessibility3 while every value remains a VoiceOver item.
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
        RideStatsRow(
            isTracking: isTracking,
            duration: duration,
            elapsedDuration: nil,
            speedLabel: LocalizationHelper.localized("Speed"),
            speedValue: speedValue,
            speedUnit: speedUnit,
            speedAccessibilityValue: speedAccessibilityValue,
            distanceValue: distanceValue,
            distanceUnit: distanceUnit,
            distanceAccessibilityValue: distanceAccessibilityValue
        )
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 12, x: 0, y: 6)
        .environment(\.dynamicTypeSize, dynamicTypeSize > .accessibility3 ? .accessibility3 : dynamicTypeSize)
    }
}

private struct RideStatsRow: View {
    let isTracking: Bool
    let duration: String
    let elapsedDuration: String?
    let speedLabel: String
    let speedValue: String
    let speedUnit: String
    let speedAccessibilityValue: String
    let distanceValue: String
    let distanceUnit: String
    let distanceAccessibilityValue: String

    @ScaledMetric(relativeTo: .title3) private var dividerHeight: CGFloat = 38

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                RideStatReadout(
                    label: LocalizationHelper.localized("Distance"),
                    value: distanceValue,
                    unit: distanceUnit,
                    accessibilityValue: distanceAccessibilityValue
                )

                Divider().frame(height: dividerHeight)

                if isTracking {
                    DurationStatReadout(
                        duration: duration,
                        elapsedDuration: elapsedDuration
                    )
                    Divider().frame(height: dividerHeight)
                }

                RideStatReadout(
                    label: speedLabel,
                    value: speedValue,
                    unit: speedUnit,
                    accessibilityValue: speedAccessibilityValue
                )
            }

            VStack(spacing: 10) {
                RideStatReadout(
                    label: LocalizationHelper.localized("Distance"),
                    value: distanceValue,
                    unit: distanceUnit,
                    accessibilityValue: distanceAccessibilityValue
                )
                if isTracking {
                    Divider()
                    DurationStatReadout(
                        duration: duration,
                        elapsedDuration: elapsedDuration
                    )
                }
                Divider()
                RideStatReadout(
                    label: speedLabel,
                    value: speedValue,
                    unit: speedUnit,
                    accessibilityValue: speedAccessibilityValue
                )
            }
        }
    }
}

private struct DurationStatReadout: View {
    let duration: String
    let elapsedDuration: String?

    var body: some View {
        VStack(spacing: 2) {
            RideStatReadout(
                label: LocalizationHelper.localized("Duration"),
                value: duration,
                unit: "",
                accessibilityValue: duration
            )
            if let elapsedDuration {
                Text(LocalizationHelper.formatted("Total %@", elapsedDuration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizationHelper.localized("Duration"))
        .accessibilityValue(elapsedDuration.map { "\(duration), total \($0)" } ?? duration)
    }
}

internal struct RideStatReadout: View {
    let label: String
    let value: String
    let unit: String
    let accessibilityValue: String

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 23

    internal var accessibilityDescriptor: RideStatAccessibilityDescriptor {
        RideStatAccessibilityDescriptor(label: label, value: accessibilityValue)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(label)
                .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
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

struct ActiveRideHUD: View {
    let trackingState: TrackingState
    let persona: RidePersona
    let isAutoPaused: Bool
    let isLiveSharing: Bool
    let isLiveShareStarting: Bool
    let isLiveShareAuthenticated: Bool
    let isOffline: Bool
    let duration: String
    let elapsedDuration: String
    let speedLabel: String
    let speedValue: String
    let speedUnit: String
    let speedAccessibilityValue: String
    let distanceValue: String
    let distanceUnit: String
    let distanceAccessibilityValue: String
    let onPauseToggle: () -> Void
    let onStop: () -> Void
    let onStartShare: () -> Void
    let onStopShare: () -> Void
    let onShareLink: () -> Void
    let onCopyLink: () -> Void
    let onShareAuthRequired: () -> Void

    private var isPaused: Bool {
        trackingState == .paused || trackingState == .storageLow
    }

    var body: some View {
        VStack(spacing: 8) {
            RideStatusChips(
                trackingState: trackingState,
                persona: persona,
                isAutoPaused: isAutoPaused,
                isLiveSharing: isLiveSharing,
                isOffline: isOffline
            )

            VStack(spacing: 12) {
                RideStatsRow(
                    isTracking: true,
                    duration: duration,
                    elapsedDuration: elapsedDuration,
                    speedLabel: speedLabel,
                    speedValue: speedValue,
                    speedUnit: speedUnit,
                    speedAccessibilityValue: speedAccessibilityValue,
                    distanceValue: distanceValue,
                    distanceUnit: distanceUnit,
                    distanceAccessibilityValue: distanceAccessibilityValue
                )

                Divider()

                if !isLiveShareAuthenticated {
                    Text(LocalizationHelper.localized("Sign in to share your live location."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 12) {
                    UnifiedPauseStopSlider(
                        isPaused: isPaused,
                        onPauseToggle: onPauseToggle,
                        onStop: onStop
                    )

                    LiveShareActionDrawer(
                        isActive: isLiveSharing,
                        isStarting: isLiveShareStarting,
                        isAuthenticated: isLiveShareAuthenticated,
                        onStart: onStartShare,
                        onStop: onStopShare,
                        onShare: onShareLink,
                        onCopy: onCopyLink,
                        onAuthRequired: onShareAuthRequired
                    )
                }
                .frame(height: 54)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
    }
}

private struct RideStatusChips: View {
    let trackingState: TrackingState
    let persona: RidePersona
    let isAutoPaused: Bool
    let isLiveSharing: Bool
    let isOffline: Bool

    var body: some View {
        CenteredFlowLayout(spacing: 8) {
            RideStatusChip(
                title: LocalizationHelper.localized(persona.displayName),
                systemImage: persona.systemImage,
                background: BrandColor.warning,
                foreground: BrandColor.onWarning
            )

            if isAutoPaused || trackingState == .paused {
                RideStatusChip(
                    title: LocalizationHelper.localized(isAutoPaused ? "Auto Paused" : "Paused"),
                    systemImage: "pause.fill",
                    background: BrandColor.warning,
                    foreground: BrandColor.onWarning
                )
            }

            if isLiveSharing {
                RideStatusChip(
                    title: LocalizationHelper.localized("Live sharing"),
                    systemImage: "antenna.radiowaves.left.and.right",
                    background: BrandColor.cyanBright,
                    foreground: BrandColor.navy900
                )
            }

            if isOffline {
                RideStatusChip(
                    title: LocalizationHelper.localized("Offline shield"),
                    systemImage: "shield.checkered",
                    background: BrandColor.success,
                    foreground: .white
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct RideStatusChip: View {
    let title: String
    let systemImage: String
    let background: Color
    let foreground: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(background, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
    }
}

private struct CenteredFlowLayout: Layout {
    let spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width ?? .infinity
        let rows = makeRows(maxWidth: proposedWidth, subviews: subviews)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let additionalWidth = row.indices.isEmpty ? size.width : spacing + size.width
            if !row.indices.isEmpty, row.width + additionalWidth > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.indices.append(index)
            row.width += row.indices.count == 1 ? size.width : spacing + size.width
            row.height = max(row.height, size.height)
        }

        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

internal enum RideStopSliderPolicy {
    static let completionFraction: CGFloat = 0.75

    static func shouldStop(translation: CGFloat, maxSlide: CGFloat) -> Bool {
        guard maxSlide > 0 else { return false }
        return -translation >= maxSlide * completionFraction
    }
}

struct UnifiedPauseStopSlider: View {
    let isPaused: Bool
    let onPauseToggle: () -> Void
    let onStop: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isStopping = false

    var body: some View {
        GeometryReader { proxy in
            let halfWidth = proxy.size.width / 2

            ZStack(alignment: .leading) {
                Capsule().fill(BrandColor.primaryFill)

                Button {
                    guard !isStopping else { return }
                    Haptics.impact(.medium)
                    onPauseToggle()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.title3.bold())
                        .foregroundStyle(BrandColor.onPrimary)
                        .frame(width: halfWidth, height: 54)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(LocalizationHelper.localized(isPaused ? "Resume tracking" : "Pause tracking"))

                stopThumb(maxSlide: halfWidth)
                    .frame(width: halfWidth, height: 54)
                    .offset(x: halfWidth + dragOffset)
            }
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
    }

    private func stopThumb(maxSlide: CGFloat) -> some View {
        ZStack {
            Capsule().fill(isStopping ? BrandColor.destructiveDeep : BrandColor.destructive)
            if isStopping {
                Label(LocalizationHelper.localized("Ride stopped"), systemImage: "stop.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left.2")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Image(systemName: "stop.fill")
                        .font(.body.bold())
                        .foregroundStyle(BrandColor.destructive)
                        .frame(width: 40, height: 40)
                        .background(.white, in: Circle())
                }
            }
        }
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard !isStopping else { return }
                    dragOffset = min(0, max(-maxSlide, value.translation.width))
                    if RideStopSliderPolicy.shouldStop(
                        translation: dragOffset,
                        maxSlide: maxSlide
                    ) {
                        requestStop(maxSlide: maxSlide)
                    }
                }
                .onEnded { _ in
                    guard !isStopping else { return }
                    withAnimation(.easeOut(duration: 0.24)) { dragOffset = 0 }
                }
        )
        .onTapGesture {
            guard !isStopping else { return }
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.16)) { dragOffset = -maxSlide * 0.35 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !isStopping else { return }
                withAnimation(.easeOut(duration: 0.22)) { dragOffset = 0 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizationHelper.localized("Stop tracking"))
        .accessibilityHint(LocalizationHelper.localized("Slide left to stop the ride"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { requestStop(maxSlide: maxSlide) }
    }

    private func requestStop(maxSlide: CGFloat) {
        guard !isStopping else { return }
        isStopping = true
        Haptics.notify(.warning)
        withAnimation(.easeOut(duration: 0.15)) { dragOffset = -maxSlide }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            onStop()
        }
    }
}

struct LiveShareActionDrawer: View {
    let isActive: Bool
    let isStarting: Bool
    let isAuthenticated: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onShare: () -> Void
    let onCopy: () -> Void
    let onAuthRequired: () -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            guard isAuthenticated else {
                onAuthRequired()
                return
            }
            guard !isStarting else { return }
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                isOpen.toggle()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isStarting {
                        ProgressView().tint(BrandColor.navy900)
                    } else {
                        Image(systemName: baseSystemImage)
                            .font(.title3.bold())
                    }
                }
                .foregroundStyle(BrandColor.navy900)
                .frame(width: 54, height: 54)
                .background(baseBackground, in: Circle())

                if isActive, !isOpen {
                    Circle()
                        .fill(BrandColor.destructive)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(baseAccessibilityLabel)
        .overlay(alignment: .bottom) {
            if isOpen, isAuthenticated {
                VStack(spacing: 8) {
                    if isActive {
                        drawerButton(
                            systemImage: "square.and.arrow.up",
                            label: "Share live link",
                            background: BrandColor.primaryFill,
                            foreground: .white,
                            action: onShare
                        )
                        drawerButton(
                            systemImage: "doc.on.doc",
                            label: "Copy live link",
                            background: BrandColor.primaryFill,
                            foreground: .white,
                            action: onCopy
                        )
                        drawerButton(
                            systemImage: "stop.fill",
                            label: "Stop live sharing",
                            background: Color(.systemRed).opacity(0.18),
                            foreground: BrandColor.destructiveText,
                            action: onStop
                        )
                    } else {
                        drawerButton(
                            systemImage: "play.fill",
                            label: "Start live sharing",
                            background: BrandColor.primaryFill,
                            foreground: .white,
                            action: onStart
                        )
                    }
                }
                .padding(5)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(y: -62)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .frame(width: 54, height: 54)
        .zIndex(20)
        .onChange(of: isStarting) { _, starting in
            if starting { isOpen = false }
        }
        .onChange(of: isActive) { _, _ in
            isOpen = false
        }
    }

    private var baseSystemImage: String {
        if !isAuthenticated { return "person.crop.circle.badge.exclamationmark" }
        if isOpen { return "xmark" }
        return "antenna.radiowaves.left.and.right"
    }

    private var baseBackground: Color {
        if !isAuthenticated { return Color(.systemGray3).opacity(0.7) }
        if isActive || isStarting { return BrandColor.cyanBright }
        if isOpen { return Color(.systemGray4) }
        return Color(.systemGray3)
    }

    private var baseAccessibilityLabel: String {
        if !isAuthenticated { return LocalizationHelper.localized("Sign in to share your live location.") }
        if isStarting { return LocalizationHelper.localized("Starting live sharing") }
        if isOpen { return LocalizationHelper.localized("Close live sharing actions") }
        if isActive { return LocalizationHelper.localized("Live sharing actions") }
        return LocalizationHelper.localized("Start live location sharing")
    }

    private func drawerButton(
        systemImage: String,
        label: String,
        background: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.medium)
            withAnimation(.easeOut(duration: 0.18)) { isOpen = false }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.body.bold())
                .foregroundStyle(foreground)
                .frame(width: 52, height: 52)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizationHelper.localized(label))
    }
}

nonisolated enum RadialStartPersonaPolicy {
    static func selection(
        hovered: RidePersona?,
        didDrag: Bool,
        releasedInsideCenter: Bool,
        preselected: RidePersona
    ) -> RidePersona? {
        if let hovered { return hovered }
        return !didDrag && releasedInsideCenter ? preselected : nil
    }
}

struct RadialStartTrackingControl: View {
    @Binding var launchState: RideStartLaunchState
    var preselectedPersona: RidePersona = .auto
    var onOpenAllPersonas: () -> Void = {}
    var onCommit: (RidePersona) -> Void

    @State private var isExpanded = false
    @State private var hoveredPersona: RidePersona?
    @State private var pendingPersona: RidePersona = .auto
    @State private var didExceedTouchSlop = false
    @State private var consumingLaunchGesture = false
    @State private var gestureStartedOnControl = false

    private let personas: [RidePersona] = [.walk, .run, .cycling, .bikeDrive, .carDrive]
    private let angles: [Double] = [160, 125, 90, 55, 20]
    private let radius: CGFloat = 108

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 50)
            let showPersonas = isExpanded || launchState.isPending

            ZStack {
                ForEach(Array(personas.enumerated()), id: \.element) { index, persona in
                    Button {
                        startPersonaImmediately(persona)
                    } label: {
                        Image(systemName: persona.systemImage)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(
                                hoveredPersona == persona ? BrandColor.primaryFill : BrandColor.primaryFill.opacity(0.68),
                                in: Circle()
                            )
                            .overlay {
                                if hoveredPersona == persona {
                                    Circle().stroke(.white, lineWidth: 2)
                                }
                            }
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                            .scaleEffect(hoveredPersona == persona ? 1.16 : 1)
                    }
                    .buttonStyle(.plain)
                    .opacity(showPersonas ? 1 : 0)
                    .position(optionPosition(index: index, center: center))
                    .disabled(!showPersonas)
                    .accessibilityHidden(!showPersonas)
                    .accessibilityLabel(LocalizationHelper.localized(persona.displayName))
                }

                if launchState.isPending {
                    Button(LocalizationHelper.localized("Change activity")) {
                        launchState.reset()
                        resetInteraction()
                        onOpenAllPersonas()
                    }
                    .buttonStyle(.bordered)
                    .position(x: center.x, y: 28)
                }

                VStack(spacing: 3) {
                    Image(systemName: centerImage)
                        .font(.system(size: 31, weight: .bold))
                    if let centerLabelPersona {
                        Text(LocalizationHelper.localized(centerLabelPersona.displayName))
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                }
                .foregroundColor(.white)
                .frame(width: 92, height: 92)
                .background(BrandColor.primaryFill.gradient)
                .clipShape(Circle())
                .scaleEffect(launchState.isPending || hoveredPersona != nil ? 1.06 : 1)
                .shadow(color: BrandColor.primaryFill.opacity(0.4), radius: 10, x: 0, y: 5)
                .overlay {
                    if launchState.isPending {
                        Circle()
                            .stroke(BrandColor.primaryFill.opacity(0.45), lineWidth: 2)
                            .scaleEffect(1.35)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .position(center)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("radialStart"))
                        .onChanged { value in
                            handleDragChanged(value, center: center)
                        }
                        .onEnded { value in
                            handleDragEnded(value, center: center)
                        }
                )
            }
            .coordinateSpace(name: "radialStart")
        }
        .frame(width: 300, height: 260)
        .accessibilityLabel(LocalizationHelper.localized("Start tracking"))
        .accessibilityValue(LocalizationHelper.localized(
            (hoveredPersona ?? preselectedPersona).displayName
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if launchState.isPending {
                commitPendingLaunch()
            } else {
                beginLaunch(preselectedPersona, awaitsPersonaChoice: true)
            }
        }
        .accessibilityActions {
            Button(LocalizationHelper.localized("Auto")) { startPersonaImmediately(.auto) }
            ForEach(personas, id: \.self) { persona in
                Button(LocalizationHelper.localized(persona.displayName)) { startPersonaImmediately(persona) }
            }
        }
        .task(id: launchState.pendingToken) {
            guard let token = launchState.pendingToken else { return }
            let persona = pendingPersona
            do {
                let delay = launchState.awaitsPersonaChoice
                    ? RideStartAbortPolicy.personaChoiceWindow
                    : RideStartAbortPolicy.preCommitDelay
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard launchState.pendingToken == token else { return }
            if launchState.awaitsPersonaChoice {
                // A bloom is an invitation, not consent to start. Lapsing only retracts it and
                // must not emit pre-commit-abort telemetry.
                launchState.reset()
                resetInteraction()
                return
            }
            guard launchState.commit(observedToken: token) else { return }
            onCommit(persona)
        }
    }

    private var centerImage: String {
        if launchState.isPending { return pendingPersona.systemImage }
        if let hoveredPersona { return hoveredPersona.systemImage }
        if isExpanded { return "xmark" }
        return preselectedPersona == .auto ? "play.fill" : preselectedPersona.systemImage
    }

    private var centerLabelPersona: RidePersona? {
        if launchState.isPending { return nil }
        if let hoveredPersona { return hoveredPersona }
        return !isExpanded && preselectedPersona != .auto ? preselectedPersona : nil
    }

    private func optionPosition(index: Int, center: CGPoint) -> CGPoint {
        let radians = angles[index] * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y - radius * CGFloat(sin(radians))
        )
    }

    private func handleDragChanged(_ value: DragGesture.Value, center: CGPoint) {
        if consumingLaunchGesture { return }

        if launchState.isPending {
            guard distance(value.location, center) <= 54,
                  let token = launchState.pendingToken else { return }
            
            if launchState.awaitsPersonaChoice {
                let persona = pendingPersona
                guard launchState.commit(observedToken: token) else { return }
                consumingLaunchGesture = true
                Haptics.impact(.medium)
                onCommit(persona)
            } else {
                guard launchState.abort(observedToken: token) else { return }
                consumingLaunchGesture = true
                Haptics.notify(.warning)
                onAbort(.preCommit)
            }
            return
        }

        if !gestureStartedOnControl {
            guard distance(value.startLocation, center) <= 54 else { return }
            gestureStartedOnControl = true
        }

        if !isExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.76)) {
                isExpanded = true
            }
            Haptics.impact(.medium)
        }

        didExceedTouchSlop = didExceedTouchSlop || distance(value.location, value.startLocation) > 10
        let nextHovered = personas.enumerated()
            .map { ($0.element, distance(value.location, optionPosition(index: $0.offset, center: center))) }
            .filter { $0.1 <= 38 }
            .min { $0.1 < $1.1 }?.0

        if nextHovered != hoveredPersona {
            hoveredPersona = nextHovered
            if nextHovered != nil { Haptics.selection() }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, center: CGPoint) {
        if consumingLaunchGesture {
            consumingLaunchGesture = false
            resetInteraction()
            return
        }
        guard gestureStartedOnControl else { return }
        guard !launchState.isPending else { return }

        let selected = RadialStartPersonaPolicy.selection(
            hovered: hoveredPersona,
            didDrag: didExceedTouchSlop,
            releasedInsideCenter: distance(value.location, center) <= 54,
            preselected: preselectedPersona
        )

        if let selected {
            beginLaunch(
                selected,
                awaitsPersonaChoice: !didExceedTouchSlop && hoveredPersona == nil
            )
        } else { resetInteraction() }
    }

    private func beginLaunch(_ persona: RidePersona, awaitsPersonaChoice: Bool = false) {
        guard !launchState.isPending else { return }
        pendingPersona = persona
        launchState.begin(awaitsPersonaChoice: awaitsPersonaChoice)
        resetInteraction()
        Haptics.impact(.medium)
    }

    private func commitPendingLaunch() {
        guard let token = launchState.pendingToken else { return }
        let persona = pendingPersona
        guard launchState.commit(observedToken: token) else { return }
        resetInteraction()
        Haptics.impact(.medium)
        onCommit(persona)
    }

    private func startPersonaImmediately(_ persona: RidePersona) {
        launchState.reset()
        pendingPersona = persona
        resetInteraction()
        Haptics.impact(.medium)
        onCommit(persona)
    }

    private func resetInteraction() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = false
            hoveredPersona = nil
        }
        didExceedTouchSlop = false
        gestureStartedOnControl = false
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
