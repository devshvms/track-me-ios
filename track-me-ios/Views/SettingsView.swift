import SwiftUI
import FirebaseAuth
import SwiftData

struct SettingsView: View {
    @AppStorage("enableGPSPostProcessing") var isPostProcessingEnabled: Bool = true
    @AppStorage("intelligentAutoPause") var isAutoPauseEnabled: Bool = true
    @State private var isLoggedOut = Auth.auth().currentUser == nil

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
        NavigationStack {
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

                            Button(action: {
                                Auth.auth().signInAnonymously { result, error in
                                    if let error = error {
                                        print("Anonymous sign in error: \(error.localizedDescription)")
                                    } else if let authResult = result {
                                        TelemetryManager.shared.identifyUser(userId: authResult.user.uid)
                                        if authResult.additionalUserInfo?.isNewUser == true {
                                            TelemetryManager.shared.trackUserSignedUp()
                                        } else {
                                            TelemetryManager.shared.trackUserLoggedIn()
                                        }
                                    }
                                }
                            }) {
                                Text("Sign in (Anonymous Test)")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(BrandColor.primaryFill)
                                    .foregroundColor(.white)
                                    .cornerRadius(24)
                            }
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
                                    Text("Oct 2023") // Hardcoded or format from Auth metadata if available
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
                            NavigationLink(destination: AccountManagementView()) {
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
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationHelper.localized("Intelligent Auto-Pause")).font(.subheadline)
                                Text(LocalizationHelper.localized("Dynamically pauses the moving timer at traffic signals or stops based on activity speed.")).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Toggle("", isOn: $isAutoPauseEnabled).labelsHidden().accessibilityLabel(LocalizationHelper.localized("Intelligent auto-pause"))
                        }
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
                                .onChange(of: isTelemetryEnabled) { _ in
                                    TelemetryManager.shared.updateOptOutStatus()
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
                Auth.auth().addStateDidChangeListener { _, user in
                    isLoggedOut = (user == nil)
                }
            }
        }
        .trackScreen("SettingsView")
    }
}
