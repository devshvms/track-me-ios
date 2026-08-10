import Combine
import Foundation
import StoreKit

struct AppUpdateInfo: Equatable, Identifiable {
    var id: String { latestVersionName }
    let latestVersionName: String
    let releaseNotes: String
    let updateURL: URL
}

struct AppStoreLookupResponse: Decodable, Equatable {
    let resultCount: Int
    let results: [AppStoreLookupResult]
}

struct AppStoreLookupResult: Decodable, Equatable {
    let version: String
    let releaseNotes: String?
    let trackViewUrl: String
}

@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    @Published var updateInfo: AppUpdateInfo?

    private let session: URLSession
    private let bundle: Bundle
    private let defaults: UserDefaults

    private init(
        session: URLSession = .shared,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.bundle = bundle
        self.defaults = defaults
    }

    func checkForUpdate(forceCheck: Bool = false) async -> Bool {
        guard await canCheckForUpdates() else { return false }
        guard let bundleIdentifier = bundle.bundleIdentifier,
              let currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let storefront = await Storefront.current,
              let lookupURL = Self.lookupURL(
                bundleIdentifier: bundleIdentifier,
                countryCode: storefront.countryCode
              ) else {
            return false
        }

        do {
            let (data, response) = try await session.data(from: lookupURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }

            let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            guard lookup.resultCount > 0,
                  let offered = lookup.results.first,
                  Self.isNewerVersion(remote: offered.version, current: currentVersion),
                  let updateURL = URL(string: offered.trackViewUrl) else {
                return false
            }

            let dismissedVersion = defaults.string(forKey: Self.dismissedVersionKey)
            let dismissedAt = defaults.object(forKey: Self.dismissedAtKey) as? Date
            guard Self.shouldPrompt(
                latestVersion: offered.version,
                dismissedVersion: dismissedVersion,
                dismissedAt: dismissedAt,
                now: Date(),
                forceCheck: forceCheck
            ) else {
                return false
            }

            updateInfo = AppUpdateInfo(
                latestVersionName: offered.version,
                releaseNotes: offered.releaseNotes ?? LocalizationHelper.localized("A new version of TrackMe is available."),
                updateURL: updateURL
            )
            return true
        } catch {
            NSLog("AppUpdateManager: App Store lookup failed - %@", error.localizedDescription)
            return false
        }
    }

    func dismissUpdate(version: String) {
        defaults.set(version, forKey: Self.dismissedVersionKey)
        defaults.set(Date(), forKey: Self.dismissedAtKey)
        updateInfo = nil
    }

    static func lookupURL(bundleIdentifier: String, countryCode: String) -> URL? {
        guard !bundleIdentifier.isEmpty, !countryCode.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: countryCode.uppercased())
        ]
        return components?.url
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

    static func shouldPrompt(
        latestVersion: String,
        dismissedVersion: String?,
        dismissedAt: Date?,
        now: Date,
        forceCheck: Bool
    ) -> Bool {
        if forceCheck { return true }
        guard let dismissedVersion, let dismissedAt else { return true }
        if latestVersion != dismissedVersion { return true }
        return now.timeIntervalSince(dismissedAt) > 24 * 60 * 60
    }

    static func shouldPerformLookup(
        isDebugBuild: Bool,
        isSimulator: Bool,
        appStoreEnvironment: AppStore.Environment?
    ) -> Bool {
        !isDebugBuild && !isSimulator && appStoreEnvironment == .production
    }

    private func canCheckForUpdates() async -> Bool {
        #if DEBUG || targetEnvironment(simulator)
        return false
        #else
        let environment: AppStore.Environment?
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                environment = transaction.environment
            case .unverified:
                environment = nil
            }
        } catch {
            environment = nil
        }

        return Self.shouldPerformLookup(
            isDebugBuild: false,
            isSimulator: false,
            appStoreEnvironment: environment
        )
        #endif
    }

    private static let dismissedVersionKey = "appUpdate.dismissedVersion"
    private static let dismissedAtKey = "appUpdate.dismissedAt"
}
