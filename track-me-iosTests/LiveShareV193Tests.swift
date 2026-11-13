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
            "Duration: %@",
            "Power Saving",
            "Power saving mode active, location updates spaced out to conserve battery",
            "Retry",
            "Track my live ride on TrackMe: %@",
            "Add me as a trusted contact on TrackMe to see my live rides: %@"
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

            let formattedShareMsg = String(
                format: LocalizationHelper.localized("Track my live ride on TrackMe: %@", localeCode: lang),
                "https://trackme.shvms.in/live/abc123"
            )
            XCTAssertTrue(formattedShareMsg.contains("https://trackme.shvms.in/live/abc123"), "Share message failed in \(lang): \(formattedShareMsg)")

            let formattedWatcherMsg = String(
                format: LocalizationHelper.localized("Add me as a trusted contact on TrackMe to see my live rides: %@", localeCode: lang),
                "https://trackme.shvms.in/watcher/xyz789"
            )
            XCTAssertTrue(formattedWatcherMsg.contains("https://trackme.shvms.in/watcher/xyz789"), "Watcher message failed in \(lang): \(formattedWatcherMsg)")
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

    func testLiveViewerLowBatteryBannerLocalizationParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let localizedFormat = LocalizationHelper.localized("Rider battery low (%lld%%) · Signal may pause if phone powers off", localeCode: lang)
            XCTAssertFalse(localizedFormat.isEmpty, "Missing low battery banner for \(lang)")
            if lang != "en" {
                XCTAssertFalse(localizedFormat.contains("Rider battery low"), "Untranslated banner for \(lang)")
            }

            let formatted = String(format: localizedFormat, 12)
            XCTAssertTrue(formatted.contains("12"), "Formatted low battery banner output should contain '12' in \(lang): \(formatted)")
        }
    }

    func testTrustedWatcherRemovalConfirmationLocalizationParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let title = LocalizationHelper.localized("Remove trusted watcher?", localeCode: lang)
            XCTAssertFalse(title.isEmpty, "Missing title for \(lang)")
            if lang != "en" {
                XCTAssertFalse(title.contains("Remove trusted watcher?"), "Untranslated title for \(lang)")
            }

            let messageFormat = LocalizationHelper.localized("Remove %@ from trusted watchers? They will no longer receive live ride alerts automatically.", localeCode: lang)
            XCTAssertFalse(messageFormat.isEmpty, "Missing message format for \(lang)")
            if lang != "en" {
                XCTAssertFalse(messageFormat.contains("They will no longer receive"), "Untranslated message for \(lang)")
            }

            let formatted = String(format: messageFormat, "Alex")
            XCTAssertTrue(formatted.contains("Alex"), "Formatted message should contain 'Alex' in \(lang): \(formatted)")
        }
    }

    func testComputePathDistanceMetersHandlesJitterJumpsAndInvalidPoints() {
        // Empty or 1 point
        XCTAssertEqual(LiveSessionViewerRepository.computePathDistanceMeters([]), 0.0, accuracy: 0.001)
        XCTAssertEqual(LiveSessionViewerRepository.computePathDistanceMeters([LiveViewerPoint(lat: 12.9716, lng: 77.5946)]), 0.0, accuracy: 0.001)

        // 2 points ~111m apart
        let p1 = LiveViewerPoint(lat: 12.9716, lng: 77.5946)
        let p2 = LiveViewerPoint(lat: 12.9726, lng: 77.5946)
        let dist2 = LiveSessionViewerRepository.computePathDistanceMeters([p1, p2])
        XCTAssertTrue(dist2 >= 110.0 && dist2 <= 112.0, "Expected ~111m, got \(dist2)")

        // Discards sub-2m jitter
        let pJitter = LiveViewerPoint(lat: 12.97260001, lng: 77.5946)
        let distWithJitter = LiveSessionViewerRepository.computePathDistanceMeters([p1, p2, pJitter])
        XCTAssertEqual(distWithJitter, dist2, accuracy: 0.001)

        // Discards supersonic jump (> 50 km)
        let pJump = LiveViewerPoint(lat: 18.0, lng: 77.5946) // ~555 km away
        let distWithJump = LiveSessionViewerRepository.computePathDistanceMeters([p1, p2, pJump])
        XCTAssertEqual(distWithJump, dist2, accuracy: 0.001)

        // Skips Null Island (0,0)
        let pNullIsland = LiveViewerPoint(lat: 0.0, lng: 0.0)
        let distWithNullIsland = LiveSessionViewerRepository.computePathDistanceMeters([pNullIsland, p1, p2])
        XCTAssertEqual(distWithNullIsland, dist2, accuracy: 0.001)
    }

    func testLiveSessionSnapshotCalculatesTotalDistance() {
        let p1 = LiveViewerPoint(lat: 12.9716, lng: 77.5946)
        let p2 = LiveViewerPoint(lat: 12.9726, lng: 77.5946)
        let snapshot = LiveSessionSnapshot(
            sessionId: "test-dist",
            username: "Rider",
            status: "active",
            startedAt: nil,
            stopReason: nil,
            endReason: nil,
            endedAt: nil,
            destination: nil,
            deadlineAt: nil,
            lastLocation: nil,
            path: [p1, p2]
        )

        XCTAssertTrue(snapshot.totalDistanceMeters >= 110.0 && snapshot.totalDistanceMeters <= 112.0)
    }

    func testLiveViewerDistanceLocalizationParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let format = LocalizationHelper.localized("Distance: %@", localeCode: lang)
            XCTAssertFalse(format.isEmpty, "Missing Distance: %@ for \(lang)")
            if lang != "en" {
                XCTAssertFalse(format.hasPrefix("Distance:"), "Untranslated Distance: %@ for \(lang)")
            }

            let formatted = String(format: format, "14.2 km")
            XCTAssertTrue(formatted.contains("14.2 km"), "Formatted message should contain '14.2 km' in \(lang): \(formatted)")
        }
    }

    func testLiveViewerDeadlineEvaluationAndLocalizationParity() {
        let deadlineEpochMs: Double = 1_700_000_000_000
        let deadlineDate = Date(timeIntervalSince1970: deadlineEpochMs / 1000.0)
        let fixedFormatter: (Date) -> String = { _ in "6:30 PM" }

        // Null / empty / invalid
        XCTAssertNil(LiveSessionViewerRepository.evaluateDeadline(deadlineRaw: nil))
        XCTAssertNil(LiveSessionViewerRepository.evaluateDeadline(deadlineRaw: ""))
        XCTAssertNil(LiveSessionViewerRepository.evaluateDeadline(deadlineRaw: "invalid_deadline"))

        // On-time (15 minutes prior)
        let onTimeNow = deadlineDate.addingTimeInterval(-15 * 60)
        let onTime = LiveSessionViewerRepository.evaluateDeadline(
            deadlineRaw: "\(Int64(deadlineEpochMs))",
            now: onTimeNow,
            timeFormatter: fixedFormatter
        )
        XCTAssertNotNil(onTime)
        XCTAssertFalse(onTime?.isOverdue ?? true)
        XCTAssertEqual(onTime?.overdueMinutes, 0)
        XCTAssertEqual(onTime?.timeFormatted, "6:30 PM")

        // Overdue (25 minutes past)
        let overdueNow = deadlineDate.addingTimeInterval(25 * 60)
        let overdue = LiveSessionViewerRepository.evaluateDeadline(
            deadlineRaw: "\(Int64(deadlineEpochMs))",
            now: overdueNow,
            timeFormatter: fixedFormatter
        )
        XCTAssertNotNil(overdue)
        XCTAssertTrue(overdue?.isOverdue ?? false)
        XCTAssertEqual(overdue?.overdueMinutes, 25)
        XCTAssertEqual(overdue?.timeFormatted, "6:30 PM")

        // parseSnapshot etaAt fallback
        let jsonEta = #"{"username":"Rider","status":"active","etaAt":"1700000000000"}"#.data(using: .utf8)!
        let snap = LiveSessionViewerRepository.parseSnapshot(sessionId: "test-eta", data: jsonEta)
        XCTAssertEqual(snap?.deadlineAt, "1700000000000")
        let snapStatus = snap?.deadlineStatus(now: overdueNow, timeFormatter: fixedFormatter)
        XCTAssertTrue(snapStatus?.isOverdue ?? false)

        // 7-locale parity for Expected by %@ and Overdue · Expected by %@
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let expectedFormat = LocalizationHelper.localized("Expected by %@", localeCode: lang)
            XCTAssertFalse(expectedFormat.isEmpty, "Missing Expected by %@ for \(lang)")
            if lang != "en" {
                XCTAssertFalse(expectedFormat.hasPrefix("Expected by"), "Untranslated Expected by %@ for \(lang)")
            }
            let formattedExpected = String(format: expectedFormat, "6:30 PM")
            XCTAssertTrue(formattedExpected.contains("6:30 PM"), "Expected by in \(lang) should contain '6:30 PM': \(formattedExpected)")

            let overdueFormat = LocalizationHelper.localized("Overdue · Expected by %@", localeCode: lang)
            XCTAssertFalse(overdueFormat.isEmpty, "Missing Overdue · Expected by %@ for \(lang)")
            if lang != "en" {
                XCTAssertFalse(overdueFormat.hasPrefix("Overdue · Expected by"), "Untranslated Overdue · Expected by %@ for \(lang)")
            }
            let formattedOverdue = String(format: overdueFormat, "6:30 PM")
            XCTAssertTrue(formattedOverdue.contains("6:30 PM"), "Overdue in \(lang) should contain '6:30 PM': \(formattedOverdue)")
        }
    }

    func testLiveViewerShareRideFormattingAndLocaleParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        let testUrl = "https://trackme.shvms.in/live/abc-123"

        for lang in languages {
            let shareRideLabel = LocalizationHelper.localized("Share Ride", localeCode: lang)
            XCTAssertFalse(shareRideLabel.isEmpty, "Missing Share Ride for \(lang)")
            if lang != "en" {
                XCTAssertNotEqual(shareRideLabel, "Share Ride", "Untranslated Share Ride for \(lang)")
            }

            let shareA11y = LocalizationHelper.localized("Share this live tracking session", localeCode: lang)
            XCTAssertFalse(shareA11y.isEmpty, "Missing Share this live tracking session for \(lang)")
            if lang != "en" {
                XCTAssertNotEqual(shareA11y, "Share this live tracking session", "Untranslated Share this live tracking session for \(lang)")
            }

            let subject = LocalizationHelper.localized("TrackMe Live Ride", localeCode: lang)
            XCTAssertFalse(subject.isEmpty, "Missing TrackMe Live Ride for \(lang)")

            let formatWithName = LocalizationHelper.localized("Track %@'s live ride on TrackMe: %@", localeCode: lang)
            XCTAssertFalse(formatWithName.isEmpty, "Missing Track %@'s live ride on TrackMe: %@ for \(lang)")
            let formattedWithName = String(format: formatWithName, "Alice", testUrl)
            XCTAssertTrue(formattedWithName.contains("Alice"), "\(lang) formatted message should contain 'Alice': \(formattedWithName)")
            XCTAssertTrue(formattedWithName.contains(testUrl), "\(lang) formatted message should contain '\(testUrl)': \(formattedWithName)")

            let formatFallback = LocalizationHelper.localized("Track this live ride on TrackMe: %@", localeCode: lang)
            XCTAssertFalse(formatFallback.isEmpty, "Missing Track this live ride on TrackMe: %@ for \(lang)")
            let formattedFallback = String(format: formatFallback, testUrl)
            XCTAssertTrue(formattedFallback.contains(testUrl), "\(lang) formatted fallback should contain '\(testUrl)': \(formattedFallback)")
        }
    }
}
