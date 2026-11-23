import SwiftUI
import FirebaseAuth
import SwiftData

private enum SignInProvider: Equatable {
    case apple
    case google
}

struct SettingsView: View {
    /// TASK-226: bumped when the rider double-taps this tab. Pops back to the settings list.
    var popToRootRequest: Int = 0
    @State private var navigationPath: [SettingsRoute] = []
    /// TASK-277: one derivation for both the signed-in and signed-out cards.
    @State private var levelIndex: Int = 0

    @AppStorage("debugModeEnabled") private var debugModeEnabled = false
    @State private var isLoggedOut = Auth.auth().currentUser == nil || Auth.auth().currentUser?.isAnonymous == true
    @State private var isSigningIn = false
    @State private var signingInProvider: SignInProvider?
    @State private var authStateListenerHandle: AuthStateDidChangeListenerHandle?

    @State private var isSyncing = false
    @State private var lastSyncString = FirestoreSyncManager.formattedLastSyncTime()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiveShareFrequencySliderPolicy.prefKey) var liveShareFrequency: Int = LiveShareFrequencySliderPolicy.defaultSeconds
    @State private var liveShareSliderIndex: Double
    @State private var isDraggingLiveShareSlider = false
    @State private var showLiveShareInfo = false

    init(popToRootRequest: Int = 0) {
        self.popToRootRequest = popToRootRequest
        let stored = UserDefaults.standard.object(forKey: LiveShareFrequencySliderPolicy.prefKey) as? Int
            ?? LiveShareFrequencySliderPolicy.defaultSeconds
        _liveShareSliderIndex = State(
            initialValue: Double(LiveShareFrequencySliderPolicy.index(forSeconds: stored))
        )
    }

    @AppStorage("enableTelemetry") var isTelemetryEnabled: Bool = false
    @AppStorage("autoTripChainingEnabled") private var autoTripChainingEnabled = false
    @AppStorage("autoEndDwellMinutes") private var autoEndDwellMinutes = 10
    @AppStorage("autoEndCropDwellEnabled") private var autoEndCropDwellEnabled = true

    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "system"
    @ObservedObject private var unitSettings = UnitSettings.shared
    @Bindable private var bulletin = BulletinStore.shared
    // Static so the shipped set can be regression-tested without instantiating the View
    // (see track-me-iosTests/LanguagePickerTests.swift). Codes must match the
    // Localizable.xcstrings localization keys exactly so Locale(identifier:) resolves the
    // right *.lproj — Chinese is "zh-Hans" (Simplified only), NOT Android's "zh".
    static let languages = [
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("hi", "हिन्दी"),
        ("ja", "日本語"),
        ("zh-Hans", "中文")
    ]

    // We get total rides from SwiftData
    @Query private var allRides: [Ride]

    private func refreshLevel() {
        guard let summary = HomeDashboardRepository.shared.summary else { return }
        levelIndex = GamificationTrail.levelIndex(
            for: GamificationEngine.deriveSnapshot(facts: summary.toGamificationFacts())
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 24) {

                    if isLoggedOut {
                        // Logged-out Card
                        VStack(spacing: 16) {
                            // TASK-277: the ring shows signed out too. Levels derive from local
                            // rides, which need no account — this card's own subtitle says the
                            // history is local only.
                            LevelAvatar(levelIndex: levelIndex, diameter: 80) {
                                ZStack {
                                    Circle().fill(Color.gray.opacity(0.3))
                                    Image(systemName: "person.fill")
                                        .resizable().scaledToFit()
                                        .frame(width: 40, height: 40)
                                        .foregroundColor(.primary)
                                }
                            }

                            Text("Guest")
                                .font(.title2).bold()
                                .foregroundColor(.primary)
                            Text("Ride history is saved locally only.")
                                .font(.subheadline)
                                .foregroundColor(.gray)

                            Button(action: { signIn(using: .apple) }) {
                                signInLabel(for: .apple, title: "Sign in with Apple", foreground: BrandColor.onPrimary)
                            }
                            .disabled(isSigningIn)
                            .accessibilityLabel(LocalizationHelper.localized("Sign in with Apple"))
                            .accessibilityValue(signingInProvider == .apple ? LocalizationHelper.localized("Signing in…") : "")

                            Button(action: { signIn(using: .google) }) {
                                signInLabel(for: .google, title: "Sign in with Google", foreground: BrandColor.primary)
                            }
                            .disabled(isSigningIn)
                            .accessibilityLabel(LocalizationHelper.localized("Sign in with Google"))
                            .accessibilityValue(signingInProvider == .google ? LocalizationHelper.localized("Signing in…") : "")
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                    } else {
                        // Logged-in Card
                        VStack(spacing: 0) {
                            // Header
                            HStack(spacing: 16) {
                                LevelAvatar(levelIndex: levelIndex, diameter: 64) {
                                    if let photoUrl = Auth.auth().currentUser?.photoURL {
                                        AsyncImage(url: photoUrl) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            ProgressView()
                                        }
                                    } else {
                                        ZStack {
                                            Circle().fill(Color.gray.opacity(0.3))
                                            Image(systemName: "person.fill")
                                                .resizable().scaledToFit()
                                                .frame(width: 32, height: 32)
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Auth.auth().currentUser?.displayName ?? "Explorer")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(Auth.auth().currentUser?.email ?? "")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                            }
                            .padding()

                            // Stats Row
                            HStack {
                                VStack {
                                    Text("\(allRides.count)")
                                        .font(.title3).bold()
                                        .foregroundColor(BrandColor.primary)
                                    Text("Total Rides")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                .frame(maxWidth: .infinity)

                                VStack {
                                    Text(joinedDateString)
                                        .font(.title3).bold()
                                        .foregroundColor(BrandColor.primary)
                                    Text("Joined")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 8)

                            Divider().background(Color.gray).padding(.horizontal)

                            // v1.6.0 Sync Row
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cloud Sync")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(LocalizationHelper.formatted("Last synced: %@", lastSyncString))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Button(action: {
                                    guard !isSyncing else { return }
                                    isSyncing = true
                                    FirestoreSyncManager.shared.syncAll(localRides: allRides) { success in
                                        isSyncing = false
                                        lastSyncString = FirestoreSyncManager.formattedLastSyncTime()
                                    }
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(BrandColor.primary.opacity(0.15))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(BrandColor.primary)
                                            .rotationEffect(.degrees(isSyncing ? 360 : 0))
                                            .animation(isSyncing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isSyncing)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()

                            // Account Management Button
                            NavigationLink(value: SettingsRoute.accountManagement) {
                                Text("Account Management")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(BrandColor.primaryFill)
                                    .foregroundColor(.primary)
                                    .cornerRadius(24)
                            }
                            .padding([.horizontal, .bottom])
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                    }

                    // Preferences Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Preferences")
                            .font(.headline)
                            .foregroundColor(.primary)

                        HStack {
                            Text("Language")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Picker("Language", selection: $appLanguage) {
                                ForEach(Self.languages, id: \.0) { code, name in
                                    Text(name).tag(code)
                                }
                            }
                            .tint(BrandColor.primary)
                        }

                        Divider()

                        HStack {
                            Text("Theme")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Picker("Theme", selection: $appTheme) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .tint(BrandColor.primary)
                        }

                        Divider()

                        HStack {
                            Text(LocalizationHelper.localized("Units"))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Picker(LocalizationHelper.localized("Units"), selection: Binding(
                                get: { unitSettings.unit },
                                set: { unitSettings.set($0) }
                            )) {
                                Text(LocalizationHelper.localized("Kilometers (km)")).tag(UnitSystem.metric)
                                Text(LocalizationHelper.localized("Miles (mi)")).tag(UnitSystem.imperial)
                            }
                            .tint(BrandColor.primary)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // Live Location Sharing Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Live Location Sharing")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button(action: { showLiveShareInfo = true }) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.gray)
                                    .font(.title3)
                            }
                        }

                        let selectedSeconds = LiveShareFrequencySliderPolicy.seconds(forSliderValue: liveShareSliderIndex)
                        let selectedLabel = Self.formatLiveShareInterval(selectedSeconds)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(LocalizationHelper.localized("Live location updates"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Group {
                                    if reduceMotion {
                                        Text(selectedLabel)
                                    } else {
                                        Text(selectedLabel)
                                            .contentTransition(.numericText())
                                            .animation(.easeOut(duration: 0.14), value: selectedLabel)
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundColor(BrandColor.primary)
                                .accessibilityIdentifier("live_share_frequency_value")
                            }

                            Slider(
                                value: $liveShareSliderIndex,
                                in: 0...Double(LiveShareFrequencySliderPolicy.maxIndex),
                                step: 1,
                                onEditingChanged: { editing in
                                    isDraggingLiveShareSlider = editing
                                    if !editing {
                                        commitLiveShareFrequencySlider()
                                    }
                                }
                            )
                            .tint(BrandColor.primary)
                            .accessibilityLabel(LocalizationHelper.localized("Live location updates"))
                            .accessibilityValue(selectedLabel)
                            .accessibilityIdentifier("live_share_frequency_slider")
                            .onChange(of: liveShareSliderIndex) { oldValue, newValue in
                                let oldStep = Int(oldValue.rounded())
                                let newStep = Int(newValue.rounded())
                                let targetSeconds = LiveShareFrequencySliderPolicy.seconds(forSliderValue: newValue)
                                let isUserDriven = isDraggingLiveShareSlider || targetSeconds != liveShareFrequency
                                if oldStep != newStep && isUserDriven {
                                    Haptics.selection()
                                }
                                // VoiceOver adjustable swipe up/down changes the value without
                                // bracketing via onEditingChanged(true/false); persist immediately
                                // when not inside a touch drag.
                                if !isDraggingLiveShareSlider && targetSeconds != liveShareFrequency {
                                    commitLiveShareFrequencySlider()
                                }
                            }

                            HStack(alignment: .top, spacing: 12) {
                                Text(LocalizationHelper.localized("Less battery use"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(LocalizationHelper.localized("More frequent updates"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(LocalizationHelper.localized("Shorter intervals can use more battery."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // SCOPE_1.8.7 §6.1.3 #12a. Placed above privacy rather than buried in Advanced:
                    // someone who wants to turn a reminder off should find it where they would look
                    // for it, and a setting the user cannot find is a setting they cannot revoke.
                    ActivityReminderCard()

                    // Privacy & Analytics Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Privacy & Analytics")
                            .font(.headline)
                            .foregroundColor(.primary)

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Share Analytics Data")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text("Help us improve by securely sharing anonymous app usage data (e.g., ride durations, crashes). No identifiable personal data is ever shared.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Toggle("", isOn: $isTelemetryEnabled)
                                .labelsHidden()
                                .tint(BrandColor.primary)
                                .accessibilityLabel(LocalizationHelper.localized("Share analytics data"))
                                .onChange(of: isTelemetryEnabled) { _, enabled in
                                    TelemetryManager.shared.updateLocalConsent(enabled)
                                }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // Advanced Settings Card (TASK-369)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizationHelper.localized("Advanced Settings"))
                            .font(.headline)
                            .foregroundColor(.primary)

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationHelper.localized("Continuous Trip Tracking"))
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(LocalizationHelper.localized("Automatically completes your ride when stopped indoors, and auto-starts the next ride when moving again."))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Toggle("", isOn: $autoTripChainingEnabled)
                                .labelsHidden()
                                .tint(BrandColor.primary)
                                .accessibilityLabel(LocalizationHelper.localized("Continuous Trip Tracking"))
                                .onChange(of: autoTripChainingEnabled) { _, enabled in
                                    if enabled {
                                        TelemetryManager.shared.trackHandsFreeEnabled(
                                            surface: "settings",
                                            dwellMinutes: autoEndDwellMinutes
                                        )
                                    } else {
                                        TelemetryManager.shared.trackHandsFreeDisabled(surface: "settings")
                                    }
                                }
                        }

                        if autoTripChainingEnabled {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text(LocalizationHelper.localized("Auto-End Inactivity Window"))
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(String(format: LocalizationHelper.localized("Duration of dwelling indoors before automatically ending the ride (%lld minutes)."), Int64(autoEndDwellMinutes)))
                                    .font(.caption)
                                    .foregroundColor(.gray)

                                Picker("", selection: $autoEndDwellMinutes) {
                                    Text("5 min").tag(5)
                                    Text("10 min").tag(10)
                                    Text("15 min").tag(15)
                                    Text("30 min").tag(30)
                                }
                                .pickerStyle(.segmented)
                            }

                            Divider()

                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizationHelper.localized("Trim Indoor Dwell Points"))
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(LocalizationHelper.localized("Prunes trailing GPS points recorded while stationary indoors so distance and pace stay accurate."))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Toggle("", isOn: $autoEndCropDwellEnabled)
                                    .labelsHidden()
                                    .tint(BrandColor.primary)
                                    .accessibilityLabel(LocalizationHelper.localized("Trim Indoor Dwell Points"))
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    if debugModeEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizationHelper.localized("Debug Settings"))
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(LocalizationHelper.localized("Diagnostic controls for controlled TrackMe testing"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            NavigationLink(value: SettingsRoute.debugSettings) {
                                Text(LocalizationHelper.localized("Open Debug Settings"))
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(BrandColor.primaryFill)
                                    .foregroundColor(.primary)
                                    .cornerRadius(24)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                    }

                    // Help & Feedback Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizationHelper.localized("Help & Feedback"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(LocalizationHelper.localized("Find quick answers or send an editable support report."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // §6.1.7 — the way in to the bulletin. Everything the interruption budget
                        // refuses lands there, so it has to be reachable without a notification
                        // having pointed at it.
                        NavigationLink(value: SettingsRoute.bulletin) {
                            HStack(spacing: 8) {
                                Text(LocalizationHelper.localized("What's new"))
                                    .font(.headline)
                                // The tab carried §6.1.7's unread dot and nothing inside Settings
                                // did, so the badge said "open Settings" and then abandoned the
                                // reader — no row admitted to being the one it meant.
                                if !bulletin.unread().isEmpty {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(BrandColor.primaryFill)
                            .foregroundColor(.primary)
                            .cornerRadius(24)
                        }
                        .accessibilityLabel(
                            bulletin.unread().isEmpty
                                ? LocalizationHelper.localized("What's new")
                                : LocalizationHelper.localized("What's new, unread")
                        )
                        NavigationLink(value: SettingsRoute.helpFeedback) {
                            Text(LocalizationHelper.localized("Open Help & Feedback"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(BrandColor.primaryFill)
                                .foregroundColor(.primary)
                                .cornerRadius(24)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    Spacer()

                    // Version Text and Check for Updates
                    VStack(spacing: 8) {
                        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
                        Text("Version \(shortVersion) (\(build))")
                            .font(.caption)
                            .foregroundColor(.gray)

                        Button(action: {
                            Task {
                                let hasUpdate = await AppUpdateManager.shared.checkForUpdate(forceCheck: true)
                                if !hasUpdate {
                                    ToastManager.shared.show(message: LocalizationHelper.localized("You're up to date"), style: .success)
                                }
                            }
                        }) {
                            Text(LocalizationHelper.localized("Check for Updates"))
                                .font(.caption)
                                .foregroundColor(BrandColor.primary)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .accountManagement: AccountManagementView()
                case .helpFeedback: HelpFeedbackView()
                case .debugSettings: DebugSettingsView()
                case .bulletin: BulletinView()
                }
            }
            .navigationTitle("")
        .task { refreshLevel() }
            .navigationBarHidden(true)
            .alert("Live Location Sharing", isPresented: $showLiveShareInfo) {
                Button("Got it", role: .cancel) { }
            } message: {
                let freqText = Self.formatLiveShareInterval(liveShareFrequency)
                Text(LocalizationHelper.formatted("When active, your location, speed, and battery level are shared securely.\n\n• Coordinates are pushed every %@.\n• Max concurrent viewers is determined by server capability (default: 100+ viewers).\n• Sharing automatically stops when the timer expires or you end your ride.", freqText))
            }
            .onAppear {
                let syncedIndex = Double(LiveShareFrequencySliderPolicy.index(forSeconds: liveShareFrequency))
                if liveShareSliderIndex != syncedIndex {
                    liveShareSliderIndex = syncedIndex
                }
                guard authStateListenerHandle == nil else { return }
                authStateListenerHandle = Auth.auth().addStateDidChangeListener { _, user in
                    isLoggedOut = (user == nil || user?.isAnonymous == true)
                }
            }
            .onChange(of: liveShareFrequency) { _, newValue in
                guard !isDraggingLiveShareSlider else { return }
                let syncedIndex = Double(LiveShareFrequencySliderPolicy.index(forSeconds: newValue))
                if liveShareSliderIndex != syncedIndex {
                    liveShareSliderIndex = syncedIndex
                }
            }
            .onDisappear {
                guard let authStateListenerHandle else { return }
                Auth.auth().removeStateDidChangeListener(authStateListenerHandle)
                self.authStateListenerHandle = nil
            }
        }
        // TASK-226: double-tapping the tab returns to the settings list.
        .onChange(of: popToRootRequest) { _, _ in navigationPath.removeAll() }
        .trackScreen("settings")
    }

    static func formatLiveShareInterval(_ seconds: Int) -> String {
        if seconds >= 60 && seconds % 60 == 0 {
            return LocalizationHelper.formatted("%@ min", String(seconds / 60))
        }
        return LocalizationHelper.formatted("%@ sec", String(seconds))
    }

    private func commitLiveShareFrequencySlider() {
        let committedSeconds = LiveShareFrequencySliderPolicy.seconds(forSliderValue: liveShareSliderIndex)
        let snappedIndex = Double(LiveShareFrequencySliderPolicy.index(forSeconds: committedSeconds))
        if liveShareSliderIndex != snappedIndex {
            liveShareSliderIndex = snappedIndex
        }
        if liveShareFrequency != committedSeconds {
            liveShareFrequency = committedSeconds
        }
    }

    @ViewBuilder
    private func signInLabel(for provider: SignInProvider, title: String, foreground: Color) -> some View {
        HStack(spacing: 10) {
            if signingInProvider == provider {
                ProgressView()
                    .tint(foreground)
                Text(LocalizationHelper.localized("Signing in…"))
            } else {
                Text(LocalizationHelper.localized(title))
            }
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(provider == .apple ? BrandColor.primaryFill : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(BrandColor.primary, lineWidth: provider == .google ? 1 : 0)
        )
        .foregroundColor(foreground)
        .cornerRadius(24)
    }

    private var joinedDateString: String {
        guard let creationDate = Auth.auth().currentUser?.metadata.creationDate else {
            return LocalizationHelper.localized("Unknown", localeCode: appLanguage)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        formatter.locale = Locale(identifier: appLanguage)
        return formatter.string(from: creationDate)
    }

    private func signIn(using provider: SignInProvider) {
        guard !isSigningIn else { return }
        isSigningIn = true
        signingInProvider = provider

        Task { @MainActor in
            let result: Result<User, Error>
            switch provider {
            case .apple:
                result = await AuthManager.shared.signInWithApple()
            case .google:
                result = await AuthManager.shared.signInWithGoogle()
            }

            isSigningIn = false
            signingInProvider = nil
            if case .failure(let error) = result,
               !AuthManager.isSignInCancellation(error) {
                ToastManager.shared.show(
                    message: AuthManager.signInErrorMessage(for: error),
                    style: .error
                )
            }
        }
    }
}

/// TASK-226: the two screens Settings can push. Value-based so the stack has a path to clear when
/// the rider double-taps the tab; the destinations themselves are unchanged.
enum SettingsRoute: Hashable {
    case accountManagement
    case helpFeedback
    case debugSettings
    /// SCOPE_1.8.7 §6.1.7 — the bulletin. Reached from Settings rather than as a fifth tab: the bar
    /// already carries four, and a permanent tab for a surface that is empty most weeks would
    /// advertise itself far more loudly than "subtle unread badge" allows.
    case bulletin
}
