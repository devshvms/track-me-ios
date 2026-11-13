import XCTest
import CoreLocation
@testable import track_me_ios

final class LiveShareV193Tests: XCTestCase {
    func testBuildStartRequestBodyIncludesDurationUsernameAndCapsWatchersAtFive() {
        let body = LiveSharingManager.buildStartRequestBody(
            durationMinutes: 60,
            username: "  Shivam  ",
            watcherUids: ["w1", "w2", "w1", " ", "w3", "w4", "w5", "w6"]
        )

        XCTAssertEqual(body["durationMinutes"] as? Int, 60)
        XCTAssertEqual(body["username"] as? String, "Shivam")
        XCTAssertEqual(body["watcherUids"] as? [String], ["w1", "w2", "w3", "w4", "w5"])
    }

    func testBuildStartRequestBodyOmitsEmptyWatchersAndNilDuration() {
        let body = LiveSharingManager.buildStartRequestBody(
            durationMinutes: nil,
            username: "   ",
            watcherUids: ["", "   "]
        )

        XCTAssertNil(body["durationMinutes"])
        XCTAssertNil(body["username"])
        XCTAssertNil(body["watcherUids"])
    }

    func testParseStartResponseExtractsSessionShareLinkAndNotifiedCount() throws {
        let json = """
        {
          "sessionId": "abc123",
          "shareLink": "https://trackme.shvms.in/live/abc123",
          "expiresAt": "2030-01-01T12:00:00.000Z",
          "notifiedWatchersCount": 3
        }
        """.data(using: .utf8)!

        let parsed = try XCTUnwrap(
            LiveSharingManager.parseStartResponse(data: json, defaultDurationMinutes: 30)
        )
        XCTAssertEqual(parsed.sessionId, "abc123")
        XCTAssertEqual(parsed.shareLink, "https://trackme.shvms.in/live/abc123")
        XCTAssertEqual(parsed.notifiedWatchersCount, 3)
    }

    func testParseActiveViewersReadsCountAndFallsBackSafely() {
        let valid = #"{"ok":true,"activeViewers":4}"#.data(using: .utf8)!
        XCTAssertEqual(LiveSharingManager.parseActiveViewers(data: valid, fallback: 1), 4)

        let negative = #"{"activeViewers":-3}"#.data(using: .utf8)!
        XCTAssertEqual(LiveSharingManager.parseActiveViewers(data: negative, fallback: 2), 0)

        let missing = #"{"ok":true}"#.data(using: .utf8)!
        XCTAssertEqual(LiveSharingManager.parseActiveViewers(data: missing, fallback: 5), 5)

        XCTAssertEqual(LiveSharingManager.parseActiveViewers(data: Data(), fallback: 2), 2)
    }

    func testParseWatcherInviteLinkSupportsHttpsAndCustomScheme() {
        let httpsURL = URL(string: "https://trackme.shvms.in/live/watcher?inviterUid=u123&inviterName=Alex%20R")!
        let httpsParsed = TrustedWatchersManager.parseWatcherInviteLink(httpsURL)
        XCTAssertEqual(httpsParsed, ParsedWatcherInviteLink(inviterUid: "u123", inviterName: "Alex R"))

        let customURL = URL(string: "trackme://live/watcher?inviterUid=u999")!
        let customParsed = TrustedWatchersManager.parseWatcherInviteLink(customURL)
        XCTAssertEqual(customParsed, ParsedWatcherInviteLink(inviterUid: "u999", inviterName: nil))

        let invalidURL = URL(string: "https://trackme.shvms.in/live/abc123")!
        XCTAssertNil(TrustedWatchersManager.parseWatcherInviteLink(invalidURL))

        let missingUID = URL(string: "https://trackme.shvms.in/live/watcher?inviterName=Alex")!
        XCTAssertNil(TrustedWatchersManager.parseWatcherInviteLink(missingUID))
    }

    func testParseInboxInviteRejectsExpiredAndAcceptsActive() {
        let now = Date(timeIntervalSince1970: 1_893_499_200) // 2030-01-01T12:00:00Z
        let activeJson = """
        {
          "invite": {
            "sessionId": "sess-1",
            "riderName": "Maya",
            "shareUrl": "https://trackme.shvms.in/live/sess-1",
            "startedAt": "2030-01-01T11:55:00.000Z",
            "expiresAt": "2030-01-01T12:30:00.000Z"
          }
        }
        """.data(using: .utf8)!
        let active = TrustedWatchersManager.parseInboxInvite(from: activeJson, now: now)
        XCTAssertEqual(active?.sessionId, "sess-1")
        XCTAssertEqual(active?.riderName, "Maya")
        XCTAssertEqual(active?.shareUrl, "https://trackme.shvms.in/live/sess-1")

        let expiredJson = """
        {
          "invite": {
            "sessionId": "sess-2",
            "riderName": "Maya",
            "expiresAt": "2030-01-01T11:59:00.000Z"
          }
        }
        """.data(using: .utf8)!
        XCTAssertNil(TrustedWatchersManager.parseInboxInvite(from: expiredJson, now: now))

        let emptyJson = #"{"invite":null}"#.data(using: .utf8)!
        XCTAssertNil(TrustedWatchersManager.parseInboxInvite(from: emptyJson, now: now))
    }

    func testBuildPushLocationBodyIncludesHeadingWhenCourseValid() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 142.5,
            speed: 5.0, // 5 m/s = 18 km/h
            timestamp: Date(timeIntervalSince1970: 1_893_499_200)
        )
        let body = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: 85, isLowPower: false)

        XCTAssertEqual(body["lat"] as? Double, 37.7749)
        XCTAssertEqual(body["lng"] as? Double, -122.4194)
        XCTAssertEqual(body["batteryLevel"] as? Int, 85)
        XCTAssertEqual(body["speed"] as? Double, 18.0)
        XCTAssertEqual(body["heading"] as? Double, 142.5)
        XCTAssertEqual(body["powerSaveMode"] as? Bool, false)
    }

    func testBuildPushLocationBodyOmitsHeadingWhenCourseNegative() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1.0, // Invalid course / stationary device
            speed: -1.0, // Invalid speed
            timestamp: Date(timeIntervalSince1970: 1_893_499_200)
        )
        let body = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: -1, isLowPower: true)

        XCTAssertEqual(body["lat"] as? Double, 37.7749)
        XCTAssertEqual(body["lng"] as? Double, -122.4194)
        XCTAssertEqual(body["batteryLevel"] as? Int, 100, "Simulator -1 battery must fall back to 100")
        XCTAssertEqual(body["speed"] as? Double, 0.0, "Invalid speed must clamp to 0")
        XCTAssertNil(body["heading"], "Negative course must be omitted from body to prevent false North locking")
        XCTAssertEqual(body["powerSaveMode"] as? Bool, true)
    }

    func testBuildPushLocationBodyEnforcesPowerSaveModeOnLowBatteryThreshold() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90.0,
            speed: 5.0,
            timestamp: Date(timeIntervalSince1970: 1_893_499_200)
        )

        // <= 15% battery triggers powerSaveMode even when OS Low Power Mode is false (CIE-015)
        let body15 = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: 15, isLowPower: false)
        XCTAssertEqual(body15["powerSaveMode"] as? Bool, true)

        let body10 = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: 10, isLowPower: false)
        XCTAssertEqual(body10["powerSaveMode"] as? Bool, true)

        let body0 = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: 0, isLowPower: false)
        XCTAssertEqual(body0["powerSaveMode"] as? Bool, true)

        // > 15% battery does not trigger powerSaveMode if OS Low Power Mode is false
        let body16 = LiveSharingManager.buildPushLocationBody(loc: loc, batteryLevel: 16, isLowPower: false)
        XCTAssertEqual(body16["powerSaveMode"] as? Bool, false)
    }

    func testIsEffectivePowerSaveAndAdaptiveInterval() {
        // Effective power save rules
        XCTAssertTrue(LiveSharingManager.isEffectivePowerSave(isOsLowPower: false, batteryLevel: 15))
        XCTAssertTrue(LiveSharingManager.isEffectivePowerSave(isOsLowPower: false, batteryLevel: 5))
        XCTAssertFalse(LiveSharingManager.isEffectivePowerSave(isOsLowPower: false, batteryLevel: 16))
        XCTAssertFalse(LiveSharingManager.isEffectivePowerSave(isOsLowPower: false, batteryLevel: 80))
        XCTAssertTrue(LiveSharingManager.isEffectivePowerSave(isOsLowPower: true, batteryLevel: 100))

        // Adaptive broadcast cadence throttling
        XCTAssertEqual(LiveSharingManager.computeAdaptiveInterval(configuredInterval: 5.0, isPowerSaveOrLowBattery: true), 15.0)
        XCTAssertEqual(LiveSharingManager.computeAdaptiveInterval(configuredInterval: 10.0, isPowerSaveOrLowBattery: true), 15.0)
        XCTAssertEqual(LiveSharingManager.computeAdaptiveInterval(configuredInterval: 30.0, isPowerSaveOrLowBattery: true), 30.0)
        XCTAssertEqual(LiveSharingManager.computeAdaptiveInterval(configuredInterval: 5.0, isPowerSaveOrLowBattery: false), 5.0)
        XCTAssertEqual(LiveSharingManager.computeAdaptiveInterval(configuredInterval: 10.0, isPowerSaveOrLowBattery: false), 10.0)
    }

    func testComputePushBackoffDelayScalesPredictablyAndClampsAtMax() {
        let noJitter = { 0.0 }
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 0, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 5.0)
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: -1, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 5.0)

        // 1 failure -> 5 + 1 = 6.0s
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 1, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 6.0)

        // 2 failures -> 5 + 3 = 8.0s
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 2, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 8.0)

        // 3 failures -> 5 + 6 = 11.0s
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 3, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 11.0)

        // 4 failures -> 5 + 10 = 15.0s (clamped to max)
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 4, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 15.0)

        // 10 failures -> clamped to max
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 10, baseInterval: 5.0, maxInterval: 15.0, randomProvider: noJitter), 15.0)

        // With jitter:
        let halfJitter = { 0.5 }
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 1, baseInterval: 5.0, maxInterval: 15.0, randomProvider: halfJitter), 6.25)
        XCTAssertEqual(LiveSharingManager.computePushBackoffDelay(consecutiveFailures: 4, baseInterval: 5.0, maxInterval: 15.0, randomProvider: halfJitter), 15.0)
    }

    func testComputeViewerBackoffSecondsScalesPredictablyAndClampsAtMax() {
        let noJitter = { 0.0 }
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 0, randomProvider: noJitter), 5.0)
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: -1, randomProvider: noJitter), 5.0)

        // 1 error -> 5 + 1 = 6.0s
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 1, randomProvider: noJitter), 6.0)

        // 2 errors -> 5 + 3 = 8.0s
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 2, randomProvider: noJitter), 8.0)

        // 3 errors -> 5 + 6 = 11.0s
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 3, randomProvider: noJitter), 11.0)

        // 4 errors -> 5 + 10 = 15.0s
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 4, randomProvider: noJitter), 15.0)

        // 10 errors -> clamped to 15.0s
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 10, randomProvider: noJitter), 15.0)

        // With jitter:
        let halfJitter = { 0.5 }
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 1, randomProvider: halfJitter), 6.25)
        XCTAssertEqual(LiveSessionViewerRepository.computeViewerBackoffSeconds(consecutiveErrors: 4, randomProvider: halfJitter), 15.0)
    }

    func testLiveViewerAccessibilityStringsResolveAcrossAllShippedLanguages() {
        let shipped = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        let keys = [
            "Location updates delayed",
            "Re-center map on rider's current location",
            "Fits the entire route trail on the map",
            "Destination: %@",
            "Rider speed: %@",
            "Rider speed unavailable",
            "Rider battery: %lld percent",
            "Rider battery low: %lld percent",
            "Opens this live tracking session in Safari",
            "The rider has ended this live trip.",
            "Signal paused",
            "GPS signal paused, waiting for rider location",
            "Signal paused · Waiting for rider GPS",
            "Duration: %@"
        ]

        for lang in shipped {
            for key in keys {
                let resolved = LocalizationHelper.localized(key, localeCode: lang)
                XCTAssertFalse(resolved.isEmpty, "Key '\(key)' resolved empty for \(lang)")
            }

            // Verify placeholder formatting
            let formattedBattery = String(
                format: LocalizationHelper.localized("Rider battery: %lld percent", localeCode: lang),
                88
            )
            XCTAssertTrue(formattedBattery.contains("88"), "Battery format failed in \(lang): \(formattedBattery)")

            let formattedLowBattery = String(
                format: LocalizationHelper.localized("Rider battery low: %lld percent", localeCode: lang),
                12
            )
            XCTAssertTrue(formattedLowBattery.contains("12"), "Low battery format failed in \(lang): \(formattedLowBattery)")

            let formattedSpeed = String(
                format: LocalizationHelper.localized("Rider speed: %@", localeCode: lang),
                "24 km/h"
            )
            XCTAssertTrue(formattedSpeed.contains("24 km/h"), "Speed format failed in \(lang): \(formattedSpeed)")

            let formattedDest = String(
                format: LocalizationHelper.localized("Destination: %@", localeCode: lang),
                "Central Station"
            )
            XCTAssertTrue(formattedDest.contains("Central Station"), "Destination format failed in \(lang): \(formattedDest)")

            let formattedDuration = String(
                format: LocalizationHelper.localized("Duration: %@", localeCode: lang),
                "45m"
            )
            XCTAssertTrue(formattedDuration.contains("45m"), "Duration format failed in \(lang): \(formattedDuration)")
        }
    }

    func testLiveViewerStaleSignalDetection() {
        let now = Date(timeIntervalSince1970: 1_700_000_200)
        let freshIso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30)) // 30s ago
        let staleIso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-200)) // > 3m ago

        // Inactive session is never stale
        XCTAssertFalse(LiveSessionViewerRepository.isStaleSignal(isActive: false, timestampIso: staleIso, now: now))

        // Active session: fresh vs stale
        XCTAssertFalse(LiveSessionViewerRepository.isStaleSignal(isActive: true, timestampIso: freshIso, now: now))
        XCTAssertTrue(LiveSessionViewerRepository.isStaleSignal(isActive: true, timestampIso: staleIso, now: now))
    }

    func testLiveViewerDurationFormatting() {
        let startEpochMs = 1_700_000_000_000.0
        let start = Date(timeIntervalSince1970: startEpochMs / 1000.0)

        // Under 1 minute
        let underOneMin = start.addingTimeInterval(40)
        XCTAssertEqual(LiveSessionViewerRepository.formatDuration(startedAtRaw: "\(Int64(startEpochMs))", now: underOneMin), "< 1m")

        // 42 minutes
        let fortyTwoMin = start.addingTimeInterval(42 * 60)
        XCTAssertEqual(LiveSessionViewerRepository.formatDuration(startedAtRaw: "\(Int64(startEpochMs))", now: fortyTwoMin), "42m")

        // Exact 2 hours
        let twoHours = start.addingTimeInterval(120 * 60)
        XCTAssertEqual(LiveSessionViewerRepository.formatDuration(startedAtRaw: "\(Int64(startEpochMs))", now: twoHours), "2h")

        // 1 hour 15 minutes
        let oneHourFifteen = start.addingTimeInterval(75 * 60)
        XCTAssertEqual(LiveSessionViewerRepository.formatDuration(startedAtRaw: "\(Int64(startEpochMs))", now: oneHourFifteen), "1h 15m")

        // Invalid
        XCTAssertNil(LiveSessionViewerRepository.formatDuration(startedAtRaw: nil))
        XCTAssertNil(LiveSessionViewerRepository.formatDuration(startedAtRaw: "invalid"))
    }
}
