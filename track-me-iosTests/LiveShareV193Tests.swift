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
            "Network offline · Retrying automatically",
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

    func testLiveViewerForegroundReconnectionEvaluation() {
        // Active and valid session: triggers immediate fetch, clears errors, resets counter
        let activeRes = LiveSessionViewerRepository.evaluateForegroundReconnection(
            isActive: true,
            isExpiredOrMissing: false
        )
        XCTAssertTrue(activeRes.shouldFetchImmediately)
        XCTAssertTrue(activeRes.resetConsecutiveErrors)
        XCTAssertTrue(activeRes.clearErrorMessage)

        // Expired or missing session: suppresses polling
        let expiredRes = LiveSessionViewerRepository.evaluateForegroundReconnection(
            isActive: true,
            isExpiredOrMissing: true
        )
        XCTAssertFalse(expiredRes.shouldFetchImmediately)
        XCTAssertTrue(expiredRes.resetConsecutiveErrors)
        XCTAssertTrue(expiredRes.clearErrorMessage)

        // Inactive / finished session: suppresses polling
        let finishedRes = LiveSessionViewerRepository.evaluateForegroundReconnection(
            isActive: false,
            isExpiredOrMissing: false
        )
        XCTAssertFalse(finishedRes.shouldFetchImmediately)
        XCTAssertTrue(finishedRes.resetConsecutiveErrors)
        XCTAssertTrue(finishedRes.clearErrorMessage)
    }

    func testLiveViewerHeadingSmoothingAcrossNorthBoundary() {
        // Crossing north clockwise: 355° to 5° should be +10° delta, not -350°
        let deltaClockwise = LiveSessionViewerRepository.computeShortestArcDelta(from: 355.0, to: 5.0)
        XCTAssertEqual(deltaClockwise, 10.0, accuracy: 0.001)
        let continuousClockwise = LiveSessionViewerRepository.computeContinuousAngle(current: 355.0, target: 5.0)
        XCTAssertEqual(continuousClockwise, 365.0, accuracy: 0.001)

        // Crossing north counter-clockwise: 5° to 355° should be -10° delta, not +350°
        let deltaCounter = LiveSessionViewerRepository.computeShortestArcDelta(from: 5.0, to: 355.0)
        XCTAssertEqual(deltaCounter, -10.0, accuracy: 0.001)
        let continuousCounter = LiveSessionViewerRepository.computeContinuousAngle(current: 5.0, target: 355.0)
        XCTAssertEqual(continuousCounter, -5.0, accuracy: 0.001)

        // Normal turn: 90° to 120°
        let deltaNormal = LiveSessionViewerRepository.computeShortestArcDelta(from: 90.0, to: 120.0)
        XCTAssertEqual(deltaNormal, 30.0, accuracy: 0.001)
        let continuousNormal = LiveSessionViewerRepository.computeContinuousAngle(current: 90.0, target: 120.0)
        XCTAssertEqual(continuousNormal, 120.0, accuracy: 0.001)

        // Preserves continuous angle across multi-revolution turns
        let multiTurn = LiveSessionViewerRepository.computeContinuousAngle(current: 725.0, target: 15.0)
        // 725 % 360 = 5°, 5° to 15° is +10° -> 725 + 10 = 735°
        XCTAssertEqual(multiTurn, 735.0, accuracy: 0.001)

        // Initial angle with nil current: should return target
        let initialAngle = LiveSessionViewerRepository.computeContinuousAngle(current: nil, target: 180.0)
        XCTAssertEqual(initialAngle, 180.0, accuracy: 0.001)

        // Edge case: NaN / Infinity
        XCTAssertEqual(LiveSessionViewerRepository.computeShortestArcDelta(from: .nan, to: 5.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(LiveSessionViewerRepository.computeContinuousAngle(current: 45.0, target: .nan), 45.0, accuracy: 0.001)
    }

    func testComputeStoppedSinceDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let locDate = Date(timeIntervalSince1970: 1_700_000_100 - 300) // 5m ago

        // In motion (speed >= 3.0 km/h) -> returns nil (clears stopped timer)
        let inMotion = LiveSessionViewerRepository.computeStoppedSinceDate(
            speedKmh: 18.5,
            previousStoppedSinceDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastLocationDate: locDate,
            now: now
        )
        XCTAssertNil(inMotion)

        // Stationary (speed < 3.0 km/h) with existing stopped timer -> preserves existing date
        let existingStopped = Date(timeIntervalSince1970: 1_700_000_050)
        let keptStopped = LiveSessionViewerRepository.computeStoppedSinceDate(
            speedKmh: 1.2,
            previousStoppedSinceDate: existingStopped,
            lastLocationDate: locDate,
            now: now
        )
        XCTAssertEqual(keptStopped, existingStopped)

        // Stationary without existing timer, recent location timestamp -> initializes to locDate
        let initFromLoc = LiveSessionViewerRepository.computeStoppedSinceDate(
            speedKmh: 0.0,
            previousStoppedSinceDate: nil,
            lastLocationDate: locDate,
            now: now
        )
        XCTAssertEqual(initFromLoc, locDate)

        // Stationary without existing timer, very stale location (> 30 min ago) -> initializes to now
        let staleLocDate = Date(timeIntervalSince1970: 1_700_000_100 - 2700)
        let initFromNow = LiveSessionViewerRepository.computeStoppedSinceDate(
            speedKmh: 0.0,
            previousStoppedSinceDate: nil,
            lastLocationDate: staleLocDate,
            now: now
        )
        XCTAssertEqual(initFromNow, now)
    }

    func testEvaluateSpeedOrStopped() {
        let now = Date(timeIntervalSince1970: 1_700_000_200)

        // 1. Moving at 25 km/h
        let moving = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 25.0,
            stoppedSinceDate: nil,
            now: now,
            useMiles: false
        )
        XCTAssertFalse(moving.isStationary)
        XCTAssertEqual(moving.displayText, "25 km/h")
        XCTAssertEqual(moving.a11yText, "Rider speed: 25 km/h")

        // 2. Moving imperial (approx 16 mph)
        let movingImperial = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 25.0,
            stoppedSinceDate: nil,
            now: now,
            useMiles: true
        )
        XCTAssertFalse(movingImperial.isStationary)
        XCTAssertEqual(movingImperial.displayText, "16 mph")
        XCTAssertEqual(movingImperial.a11yText, "Rider speed: 16 mph")

        // 3. Just stopped (< 60s) -> displays 0 km/h
        let justStopped = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 0.5,
            stoppedSinceDate: Date(timeIntervalSince1970: 1_700_000_200 - 35),
            now: now,
            useMiles: false
        )
        XCTAssertTrue(justStopped.isStationary)
        XCTAssertEqual(justStopped.displayText, "0 km/h")
        XCTAssertEqual(justStopped.a11yText, "Rider speed: 0 km/h")

        // 4. Stopped for 5 minutes (>= 60s) -> displays "Stopped · 5m"
        let stopped5m = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 0.0,
            stoppedSinceDate: Date(timeIntervalSince1970: 1_700_000_200 - 300),
            now: now,
            useMiles: false
        )
        XCTAssertTrue(stopped5m.isStationary)
        XCTAssertEqual(stopped5m.displayText, "Stopped · 5m")
        XCTAssertEqual(stopped5m.a11yText, "Rider stopped for 5m")

        // 5. Stopped for 1 hour 15 minutes -> displays "Stopped · 1h 15m"
        let stoppedLong = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 1.0,
            stoppedSinceDate: Date(timeIntervalSince1970: 1_700_000_200 - 4500),
            now: now,
            useMiles: false
        )
        XCTAssertTrue(stoppedLong.isStationary)
        XCTAssertEqual(stoppedLong.displayText, "Stopped · 1h 15m")
        XCTAssertEqual(stoppedLong.a11yText, "Rider stopped for 1h 15m")

        // 6. Null speed -> treated as stationary 0 km/h
        let nullSpeed = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: nil,
            stoppedSinceDate: nil,
            now: now,
            useMiles: false
        )
        XCTAssertTrue(nullSpeed.isStationary)
        XCTAssertEqual(nullSpeed.displayText, "0 km/h")
        XCTAssertEqual(nullSpeed.a11yText, "Rider speed: 0 km/h")
    }

    func testStoppedDurationLocalizationParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let stoppedFormat = LocalizationHelper.localized("Stopped · %@", localeCode: lang)
            XCTAssertFalse(stoppedFormat.isEmpty, "Missing Stopped · %@ for \(lang)")
            if lang != "en" {
                XCTAssertFalse(stoppedFormat.hasPrefix("Stopped ·"), "Untranslated Stopped · %@ for \(lang)")
            }

            let a11yFormat = LocalizationHelper.localized("Rider stopped for %@", localeCode: lang)
            XCTAssertFalse(a11yFormat.isEmpty, "Missing Rider stopped for %@ for \(lang)")
            if lang != "en" {
                XCTAssertFalse(a11yFormat.hasPrefix("Rider stopped for"), "Untranslated Rider stopped for %@ for \(lang)")
            }

            let formattedStopped = String(format: stoppedFormat, "12m")
            XCTAssertTrue(formattedStopped.contains("12m"), "Formatted stopped should contain 12m in \(lang): \(formattedStopped)")
            let formattedA11y = String(format: a11yFormat, "12m")
            XCTAssertTrue(formattedA11y.contains("12m"), "Formatted a11y should contain 12m in \(lang): \(formattedA11y)")
        }
    }

    func testMetricAndImperialUnitFormattingParity() {
        let now = Date(timeIntervalSince1970: 1_700_000_200)

        // 35 km/h in metric -> "35 km/h"
        let metricSpeed = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 35.0,
            stoppedSinceDate: nil,
            now: now,
            useMiles: false
        )
        XCTAssertFalse(metricSpeed.isStationary)
        XCTAssertEqual(metricSpeed.displayText, "35 km/h")
        XCTAssertEqual(metricSpeed.a11yText, "Rider speed: 35 km/h")

        // 35 km/h in imperial -> 35 * 0.621371 = 21.748 -> 22 mph
        let imperialSpeed = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 35.0,
            stoppedSinceDate: nil,
            now: now,
            useMiles: true
        )
        XCTAssertFalse(imperialSpeed.isStationary)
        XCTAssertEqual(imperialSpeed.displayText, "22 mph")
        XCTAssertEqual(imperialSpeed.a11yText, "Rider speed: 22 mph")

        // 0 km/h in imperial -> "0 mph"
        let zeroImperial = LiveSessionViewerRepository.evaluateSpeedOrStopped(
            speedKmh: 0.0,
            stoppedSinceDate: nil,
            now: now,
            useMiles: true
        )
        XCTAssertTrue(zeroImperial.isStationary)
        XCTAssertEqual(zeroImperial.displayText, "0 mph")
        XCTAssertEqual(zeroImperial.a11yText, "Rider speed: 0 mph")

        // Distance formatting
        let distanceMetric = UnitFormatter.distance(meters: 5000, unit: .metric, decimals: 1)
        XCTAssertEqual(distanceMetric, "5.0 km")

        let distanceImperial = UnitFormatter.distance(meters: 5000, unit: .imperial, decimals: 1)
        XCTAssertEqual(distanceImperial, "3.1 mi")
    }

    func testUnitToggleLocalizationParity() {
        let languages = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        for lang in languages {
            let imperialHint = LocalizationHelper.localized("Active units: imperial. Tap to switch to metric.", localeCode: lang)
            XCTAssertFalse(imperialHint.isEmpty, "Missing imperialHint for \(lang)")

            let metricHint = LocalizationHelper.localized("Active units: metric. Tap to switch to imperial.", localeCode: lang)
            XCTAssertFalse(metricHint.isEmpty, "Missing metricHint for \(lang)")

            let changedMiles = LocalizationHelper.localized("Units changed to miles and mph", localeCode: lang)
            XCTAssertFalse(changedMiles.isEmpty, "Missing changedMiles for \(lang)")

            let changedKm = LocalizationHelper.localized("Units changed to kilometers and km/h", localeCode: lang)
            XCTAssertFalse(changedKm.isEmpty, "Missing changedKm for \(lang)")
        }
    }

    func testBuildShareUrlWithRiderAttribution() {
        // Without rider name
        let urlWithoutName = LiveSessionViewerRepository.buildShareUrl(baseURL: "https://trackme.shvms.in", sessionId: "ride-123", riderName: nil)
        XCTAssertEqual(urlWithoutName?.absoluteString, "https://trackme.shvms.in/live/ride-123")

        // Trailing slash on base URL stripped
        let urlTrailingSlash = LiveSessionViewerRepository.buildShareUrl(baseURL: "https://trackme.shvms.in///", sessionId: "ride-123", riderName: "")
        XCTAssertEqual(urlTrailingSlash?.absoluteString, "https://trackme.shvms.in/live/ride-123")

        // Blank whitespace name omitted
        let urlBlankName = LiveSessionViewerRepository.buildShareUrl(baseURL: "https://trackme.shvms.in", sessionId: "ride-123", riderName: "   ")
        XCTAssertEqual(urlBlankName?.absoluteString, "https://trackme.shvms.in/live/ride-123")

        // With rider name encoded
        let urlWithName = LiveSessionViewerRepository.buildShareUrl(baseURL: "https://trackme.shvms.in", sessionId: "ride-123", riderName: "Alex Rivera")
        XCTAssertEqual(urlWithName?.absoluteString, "https://trackme.shvms.in/live/ride-123?name=Alex%20Rivera")

        // Empty session returns nil
        let urlEmptySession = LiveSessionViewerRepository.buildShareUrl(baseURL: "https://trackme.shvms.in", sessionId: "   ", riderName: "Alex")
        XCTAssertNil(urlEmptySession)
    }

    func testComputeDistanceMeters() {
        let coord1 = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let zero = LiveSessionViewerRepository.computeDistanceMeters(from: coord1, to: coord1)
        XCTAssertEqual(zero, 0.0, accuracy: 0.001)

        let coord2 = CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4194)
        let dist = LiveSessionViewerRepository.computeDistanceMeters(from: coord1, to: coord2)
        XCTAssertGreaterThan(dist, 1000.0)
    }

    func testShouldAnimateCameraDeadband() {
        let coord1 = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        // Initial target with nil last focus must animate
        XCTAssertTrue(LiveSessionViewerRepository.shouldAnimateCamera(from: nil, to: coord1))

        // Tiny jitter (< 3m displacement, e.g. ~1m) should NOT animate
        let tinyJitter = CLLocationCoordinate2D(latitude: 37.7749 + 0.00001, longitude: -122.4194)
        XCTAssertFalse(LiveSessionViewerRepository.shouldAnimateCamera(from: coord1, to: tinyJitter))

        // Larger displacement (> 3m displacement, e.g. ~5.5m) SHOULD animate
        let moved = CLLocationCoordinate2D(latitude: 37.7749 + 0.00005, longitude: -122.4194)
        XCTAssertTrue(LiveSessionViewerRepository.shouldAnimateCamera(from: coord1, to: moved))
    }

    func testShouldUpdateBearingDeadband() {
        // When stationary, bearing updates should NEVER trigger
        XCTAssertFalse(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 45.0, targetBearing: 90.0, isStationary: true))

        // Invalid target bearing
        XCTAssertFalse(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 45.0, targetBearing: nil, isStationary: false))
        XCTAssertFalse(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 45.0, targetBearing: .nan, isStationary: false))

        // First bearing when current is nil
        XCTAssertTrue(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: nil, targetBearing: 90.0, isStationary: false))

        // Small jitter (< 3 degrees) while in motion should be suppressed
        XCTAssertFalse(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 45.0, targetBearing: 47.0, isStationary: false))
        XCTAssertFalse(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 1.0, targetBearing: 359.0, isStationary: false)) // 2 degree arc

        // Substantial change (>= 3 degrees) while in motion should update
        XCTAssertTrue(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 45.0, targetBearing: 48.0, isStationary: false))
        XCTAssertTrue(LiveSessionViewerRepository.shouldUpdateBearing(currentBearing: 355.0, targetBearing: 2.0, isStationary: false)) // 7 degree arc
    }

    func testEvaluateNetworkReconnection() {
        // Disconnected during active session: show offline toast, do not fetch immediately
        let offlineState = LiveSessionViewerRepository.evaluateNetworkReconnection(
            isConnected: false,
            wasDisconnected: false,
            isActive: true,
            isExpiredOrMissing: false
        )
        XCTAssertFalse(offlineState.shouldFetchImmediately)
        XCTAssertFalse(offlineState.resetConsecutiveErrors)
        XCTAssertTrue(offlineState.showOfflineToast)

        // Reconnecting from disconnected to connected: fetch immediately, reset errors, dismiss toast
        let reconnectingState = LiveSessionViewerRepository.evaluateNetworkReconnection(
            isConnected: true,
            wasDisconnected: true,
            isActive: true,
            isExpiredOrMissing: false
        )
        XCTAssertTrue(reconnectingState.shouldFetchImmediately)
        XCTAssertTrue(reconnectingState.resetConsecutiveErrors)
        XCTAssertFalse(reconnectingState.showOfflineToast)

        // Steady online state: no toast, no immediate trigger needed
        let steadyOnline = LiveSessionViewerRepository.evaluateNetworkReconnection(
            isConnected: true,
            wasDisconnected: false,
            isActive: true,
            isExpiredOrMissing: false
        )
        XCTAssertFalse(steadyOnline.shouldFetchImmediately)
        XCTAssertFalse(steadyOnline.resetConsecutiveErrors)
        XCTAssertFalse(steadyOnline.showOfflineToast)

        // Ended or expired session: suppresses toasts and immediate fetch
        let endedState = LiveSessionViewerRepository.evaluateNetworkReconnection(
            isConnected: false,
            wasDisconnected: true,
            isActive: false,
            isExpiredOrMissing: false
        )
        XCTAssertFalse(endedState.shouldFetchImmediately)
        XCTAssertFalse(endedState.resetConsecutiveErrors)
        XCTAssertFalse(endedState.showOfflineToast)
    }
}

