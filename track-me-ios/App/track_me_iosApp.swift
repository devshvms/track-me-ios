//
//  track_me_iosApp.swift
//  track-me-ios
//
//  Created by Shivam Singh on 22/06/26.
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseMessaging
import FirebaseAuth
import GoogleSignIn
import UserNotifications

private enum AppLaunchEnvironment {
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func configureFirebase() {
        guard isUnitTesting else {
            FirebaseApp.configure()
            return
        }

        // Hosted unit tests launch the application target, but clean checkouts intentionally do
        // not contain the gitignored GoogleService-Info.plist. A syntactically valid, non-secret
        // configuration keeps FirebaseAuth available to views without contacting a real project.
        let options = FirebaseOptions(
            googleAppID: "1:000000000000:ios:0000000000000000",
            gcmSenderID: "000000000000"
        )
        options.apiKey = String(repeating: "A", count: 39)
        options.projectID = "track-me-unit-tests"
        FirebaseApp.configure(options: options)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // This must be the first launch action. Cleanup and SDK initialization below can write
        // defaults, which would make a fresh install indistinguishable from an upgrade.
        OnboardingGate.resolveAtLaunch()
        AppLaunchEnvironment.configureFirebase()
        if !AppLaunchEnvironment.isUnitTesting {
            CrashlyticsErrorLogger.shared.initialize()
            // The store is opened before Firebase exists, so a failure there cannot report itself.
            // If it fell back to memory, the rider is looking at an app with no history: say so
            // out loud rather than letting it read as "you have never ridden anywhere".
            if let failure = ModelContainerDiagnostics.shared.takeFailure() {
                CrashlyticsErrorLogger.shared.log("ModelContainer fell back to in-memory storage")
                CrashlyticsErrorLogger.shared.recordError(failure)
            }
            _ = Auth.auth().addStateDidChangeListener { _, user in
                CrashlyticsErrorLogger.shared.setUserId(user?.uid)
            }
            TelemetryManager.shared.initializePostHog()
        }
        UNUserNotificationCenter.current().delegate = self
        GroupStatusAlertCoordinator.shared.registerNotificationCategory()
        if !AppLaunchEnvironment.isUnitTesting {
            // SCOPE_1.8.7 §6.3. Registering for remote notifications does not prompt — the prompt
            // is `requestAuthorization`, which this deliberately does not call. TASK-284's rule is
            // that a permission request has to arrive at a moment that earns it, and app launch is
            // not that moment.
            application.registerForRemoteNotifications()
            // Follows the authorization the user has already given, in both directions. This is
            // also the only thing that recovers a subscription after a reinstall, a restore, or the
            // user turning notifications back on in Settings without opening anything of ours.
            BroadcastSubscription.sync()
        }
        // The age-range request is started from ContentView, where SwiftUI supplies the
        // presentation-bound requestAgeRange action required by DeclaredAgeRange.
        return true
    }

    /// SCOPE_1.8.7 §6.3 — a data-only operator broadcast.
    ///
    /// Data-only means iOS shows nothing by itself: this is where the payload is validated and,
    /// only if it survives, turned into a local notification. An `alert` payload would have been
    /// rendered before any of our code ran.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let stored = OperatorBroadcastReceiver.handle(userInfo)
            // Reporting .newData for a duplicate or a refused payload teaches iOS to throttle
            // background deliveries — including the ones the user does need.
            completionHandler(stored ? .newData : .noData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            switch response.actionIdentifier {
            case GroupStatusAlertCoordinator.muteActionIdentifier:
                GroupRideManager.shared.setAlertsMuted(true)
            case GroupStatusAlertCoordinator.viewActionIdentifier, UNNotificationDefaultActionIdentifier:
                if response.notification.request.identifier.hasPrefix(GroupStatusAlertCoordinator.notificationPrefix) {
                    GroupRideManager.shared.requestCommunityNavigation()
                }
            default:
                break
            }
            completionHandler()
        }
    }
}

@main
struct track_me_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    /// The ride store. Built by a factory that never traps — see `ModelContainerFactory` for why
    /// that matters more from 1.8.7 onwards than it did before.
    var sharedModelContainer: ModelContainer = ModelContainerFactory.make()
    
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    
    var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    if Auth.auth().canHandle(url) { return }
                    _ = GroupRideManager.shared.handleIncomingURL(url)
                }
                .onAppear {
                    DataRepository.shared.setup(container: sharedModelContainer)
                    HomeDashboardRepository.shared.configure(container: sharedModelContainer)
                    let state = OnboardingState(
                        rawValue: UserDefaults.standard.string(forKey: OnboardingGate.stateKey) ?? ""
                    ) ?? .legacy
                    try? OnboardingSampleRideSeeder.seedIfNeeded(
                        context: sharedModelContainer.mainContext,
                        onboardingState: state,
                        title: LocalizationHelper.localized("Sample ride")
                    )
                    Task {
                        await RideRecoveryManager.runLaunchRecovery(container: sharedModelContainer)
                        await HomeDashboardRepository.shared.prepare()
                        // Dismiss any Live Activity left over from a crash/force-quit.
                        RideActivityManager.shared.endOrphanedActivities(
                            activeRideId: TrackingManager.shared.currentRideId?.uuidString
                        )
                        FirestoreSyncManager.shared.syncOnForegroundIfDue()
                        // §6.3: push is the fast path, not the only one. Anyone the push missed —
                        // authorization declined, device off, APNs dropped it, subscription not
                        // yet complete — picks the broadcast up here instead, silently, because
                        // the moment to interrupt has passed.
                        await BroadcastReconciler.reconcile()
                        GroupRideManager.shared.restore()
                        _ = await AppUpdateManager.shared.checkForUpdate()
                    }
                }
                .withGlobalToasts()
                .preferredColorScheme(colorScheme)
                .environment(\.locale, Locale(identifier: appLanguage))
        }
        .modelContainer(sharedModelContainer)
    }
}
