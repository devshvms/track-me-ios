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

    @AppStorage("enableGPSPostProcessing") var isPostProcessingEnabled: Bool = true
    @AppStorage("intelligentAutoPause") var isAutoPauseEnabled: Bool = true
    @State private var isLoggedOut = Auth.auth().currentUser == nil || Auth.auth().currentUser?.isAnonymous == true
    @State private var isSigningIn = false
    @State private var signingInProvider: SignInProvider?
    @State private var authStateListenerHandle: AuthStateDidChangeListenerHandle?

    @State private var showGpsInfo = false
    @State private var isSyncing = false
    @State private var lastSyncString = FirestoreSyncManager.formattedLastSyncTime()

    @AppStorage("liveShareFrequency") var liveShareFrequency: Int = 10
    @State private var showLiveShareInfo = false

    @AppStorage("enableTelemetry") var isTelemetryEnabled: Bool = false

    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "system"
    @ObservedObject private var unitSettings = UnitSettings.shared
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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 24) {

                    if isLoggedOut {
                        // Logged-out Card
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "person.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.primary)
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
                                if let photoUrl = Auth.auth().currentUser?.photoURL {
                                    AsyncImage(url: photoUrl) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                                } else {
                                    ZStack {
                                        Circle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(width: 64, height: 64)
                                        Image(systemName: "person.fill")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 32, height: 32)
                                            .foregroundColor(.primary)
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

                        HStack {
                            Text("Update Frequency")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Picker("Frequency", selection: $liveShareFrequency) {
                                Text("5s").tag(5)
                                Text("10s").tag(10)
                                Text("30s").tag(30)
                                Text("1m").tag(60)
                                Text("5m").tag(300)
                            }
                            .tint(BrandColor.primary)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

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

                    // Advanced Settings Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Advanced Settings")
                            .font(.headline)
                            .foregroundColor(.primary)

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationHelper.localized("Intelligent Auto-Pause"))
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(LocalizationHelper.localized("Dynamically pauses the moving timer at traffic signals or stops based on activity speed."))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Toggle("", isOn: $isAutoPauseEnabled)
                                .labelsHidden()
                                .tint(BrandColor.primary)
                                .accessibilityLabel(LocalizationHelper.localized("Intelligent auto-pause"))
                        }

                        Divider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Disable GPS Post-Processing")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Button(action: { showGpsInfo = true }) {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                }
                                Text("Turn on to save raw, uncompressed data. Skipping processing increases storage and keeps glitches.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !isPostProcessingEnabled },
                                set: { isPostProcessingEnabled = !$0 }
                            ))
                            .labelsHidden()
                            .tint(BrandColor.primary)
                            .accessibilityLabel(LocalizationHelper.localized("Disable GPS post-processing"))
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // Help & Feedback Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizationHelper.localized("Help & Feedback"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(LocalizationHelper.localized("Find quick answers or send an editable support report."))
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .alert("GPS Post-Processing", isPresented: $showGpsInfo) {
                Button("Got it", role: .cancel) { }
            } message: {
                Text(LocalizationHelper.localized("This feature uses advanced algorithms to clean up your raw GPS data immediately after a ride finishes.\n\n• Filters out GPS 'teleportation' glitches.\n• Smooths out noisy altitude and speed readings.\n• Detects when you were stopped and retroactively pauses the ride.\n• Compresses the total amount of data to save storage space."))
            }
            .alert("Live Location Sharing", isPresented: $showLiveShareInfo) {
                Button("Got it", role: .cancel) { }
            } message: {
                let freqText = liveShareFrequency >= 60 ? "\(liveShareFrequency / 60) min" : "\(liveShareFrequency) sec"
                Text(LocalizationHelper.formatted("When active, your location, speed, and battery level are shared securely.\n\n• Coordinates are pushed every %@.\n• Max concurrent viewers is determined by server capability (default: 100+ viewers).\n• Sharing automatically stops when the timer expires or you end your ride.", freqText))
            }
            .onAppear {
                guard authStateListenerHandle == nil else { return }
                authStateListenerHandle = Auth.auth().addStateDidChangeListener { _, user in
                    isLoggedOut = (user == nil || user?.isAnonymous == true)
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
        .trackScreen("SettingsView")
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
}
