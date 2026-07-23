import Foundation
import FirebaseFirestore
import Combine

struct AppUpdateInfo: Equatable, Identifiable {
    var id: Int { latestBuild }
    let latestBuild: Int
    let latestVersionName: String
    let releaseNotes: String
    let isForceUpdate: Bool
    let updateURL: URL
}

@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    @Published var updateInfo: AppUpdateInfo?

    private let db = Firestore.firestore()

    // Default fallback url before Apple ID is known.
    // TODO(shvm): App Store numeric ID once enrolled (row 16)
    private let defaultUpdateURL = URL(string: "https://apps.apple.com/app/idXXXXXXXXXX")!

    private init() {}

    func checkForUpdate(forceCheck: Bool = false) async -> Bool {
        do {
            let document = try await db.collection("config").document("app_release").getDocument()
            guard let data = document.data() else { return false }

            // Read latest details
            let rawVersionCode = data["latestVersionCode"]
            let latestVersionCode = (rawVersionCode as? NSNumber)?.intValue ?? (rawVersionCode as? Int) ?? Int(rawVersionCode as? String ?? "") ?? 0
            
            let latestVersionName = data["latestVersionName"] as? String ?? ""
            let releaseNotes = data["releaseNotes"] as? String ?? "A new version of TrackMe is available."
            
            let rawForceUpdate = data["isForceUpdate"]
            let isForceUpdate = (rawForceUpdate as? NSNumber)?.boolValue ?? (rawForceUpdate as? Bool) ?? ((rawForceUpdate as? String)?.lowercased() == "true")
            let urlString = data["updateUrl"] as? String
            let updateUrl = (urlString != nil ? URL(string: urlString!) : nil) ?? defaultUpdateURL

            // Read current app details
            let currentBuildString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
            let currentBuild = Int(currentBuildString) ?? 1
            let currentVersionName = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

            if AppUpdateManager.isNewerBuild(latestBuild: latestVersionCode, currentBuild: currentBuild, latestName: latestVersionName, currentName: currentVersionName) {

                let dismissedBuild = UserDefaults.standard.integer(forKey: "appUpdate.dismissedBuild")
                let dismissedAt = UserDefaults.standard.object(forKey: "appUpdate.dismissedAt") as? Date

                if AppUpdateManager.shouldPrompt(
                    latestBuild: latestVersionCode,
                    dismissedBuild: dismissedBuild == 0 ? nil : dismissedBuild,
                    dismissedAt: dismissedAt,
                    now: Date(),
                    forceCheck: forceCheck,
                    isForce: isForceUpdate
                ) {
                    self.updateInfo = AppUpdateInfo(
                        latestBuild: latestVersionCode,
                        latestVersionName: latestVersionName,
                        releaseNotes: releaseNotes,
                        isForceUpdate: isForceUpdate,
                        updateURL: updateUrl
                    )
                    return true
                }
            }
            return false
        } catch {
            NSLog("AppUpdateManager: Failed to fetch update info - \(error.localizedDescription)")
            // Optional future fallback: iTunes Lookup API could be used here if the Firestore doc is absent.
            return false
        }
    }

    func dismissUpdate(build: Int) {
        UserDefaults.standard.set(build, forKey: "appUpdate.dismissedBuild")
        UserDefaults.standard.set(Date(), forKey: "appUpdate.dismissedAt")
        self.updateInfo = nil
    }

    static func isNewerBuild(latestBuild: Int, currentBuild: Int, latestName: String, currentName: String) -> Bool {
        if latestBuild > currentBuild {
            return true
        } else if latestBuild == currentBuild {
            // Tie-break with semver
            return isNewerVersion(remote: latestName, current: currentName)
        }
        return false
    }

    static func isNewerVersion(remote: String, current: String) -> Bool {
        let remoteParts = remote.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        let currentParts = current.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }

        let maxCount = max(remoteParts.count, currentParts.count)
        for i in 0..<maxCount {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0

            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    static func shouldPrompt(latestBuild: Int, dismissedBuild: Int?, dismissedAt: Date?, now: Date, forceCheck: Bool, isForce: Bool) -> Bool {
        if forceCheck || isForce {
            return true
        }
        guard let db = dismissedBuild, let da = dismissedAt else {
            return true // Never dismissed
        }
        if latestBuild != db {
            return true // A newer build than what was dismissed
        }
        if now.timeIntervalSince(da) > 24 * 60 * 60 {
            return true // More than 24 hours elapsed since dismissal
        }
        return false
    }

    static func isPlaceholderURLDisabled(url: URL) -> Bool {
        return url.host == "apps.apple.com" && url.path.contains("idXXXXXXXXXX")
    }
}
