//
//  track_me_iosApp.swift
//  track-me-ios
//
//  Created by Shivam Singh on 22/06/26.
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAuth

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        CrashlyticsErrorLogger.shared.initialize()
        _ = Auth.auth().addStateDidChangeListener { _, user in
            CrashlyticsErrorLogger.shared.setUserId(user?.uid)
        }
        TelemetryManager.shared.initializePostHog()
        return true
    }
}

@main
struct track_me_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Ride.self,
            GPSPoint.self,
            EmergencyContact.self,
            EmergencySettings.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
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
                .onAppear {
                    DataRepository.shared.setup(container: sharedModelContainer)
                    Task {
                        await RideRecoveryManager.runLaunchRecovery(container: sharedModelContainer)
                        // Dismiss any Live Activity left over from a crash/force-quit.
                        RideActivityManager.shared.endOrphanedActivities(
                            activeRideId: TrackingManager.shared.currentRideId?.uuidString
                        )
                        FirestoreSyncManager.shared.syncOnForegroundIfDue()
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
