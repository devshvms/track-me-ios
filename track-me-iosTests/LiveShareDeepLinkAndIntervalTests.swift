import XCTest
@testable import track_me_ios

final class LiveShareDeepLinkAndIntervalTests: XCTestCase {

    // MARK: - LiveShareLink

    func testParsesHttpsUniversalLinksForLiveSessions() {
        let primary = URL(string: "https://trackme.shvms.in/live/abc12345")!
        XCTAssertEqual(LiveShareLink.parse(url: primary), .session("abc12345"))

        let www = URL(string: "https://www.trackme.shvms.in/live/ride_99-xy?utm=share")!
        XCTAssertEqual(LiveShareLink.parse(url: www), .session("ride_99-xy"))
    }

    func testParsesCustomSchemeLiveLinks() {
        let pathBased = URL(string: "trackme://live/sess_7777")!
        XCTAssertEqual(LiveShareLink.parse(url: pathBased), .session("sess_7777"))

        let queryBased = URL(string: "trackme://live?sessionId=sess_8888")!
        XCTAssertEqual(LiveShareLink.parse(url: queryBased), .session("sess_8888"))

        let tripleSlash = URL(string: "trackme:///live/sess_3333")!
        XCTAssertEqual(LiveShareLink.parse(url: tripleSlash), .session("sess_3333"))
    }

    func testParsesUrlStringWithUnencodedQuerySpaces() {
        let parsed = LiveShareLink.parse(urlString: "https://trackme.shvms.in/live/sess_4444?utm=chat share&name=John Doe")
        XCTAssertEqual(parsed, .session("sess_4444"))
    }

    func testGroupRideManagerHandlesIncomingURLsWithWwwAndQueryCodes() {
        let manager = GroupRideManager.shared
        // 1. https with www host and token fragment
        let wwwUrl = URL(string: "https://www.trackme.shvms.in/g#Zm9vYmFyYmF6cXV4MTIzNA")!
        XCTAssertTrue(manager.handleIncomingURL(wwwUrl))
        XCTAssertEqual(manager.pendingJoinToken, "Zm9vYmFyYmF6cXV4MTIzNA")

        // 2. https path with query code fallback when fragment absent
        let queryCodeUrl = URL(string: "https://trackme.shvms.in/g?code=ABC123")!
        XCTAssertTrue(manager.handleIncomingURL(queryCodeUrl))
        XCTAssertEqual(manager.pendingJoinCode, "ABC123")

        // 3. custom scheme with path prefix
        let customSchemeUrl = URL(string: "trackme:///group?c=XYZ789")!
        XCTAssertTrue(manager.handleIncomingURL(customSchemeUrl))
        XCTAssertEqual(manager.pendingJoinCode, "XYZ789")
    }

    func testExcludesWatcherInviteLinksFromLiveSessionParsing() {
        let watcherUrl = URL(string: "https://trackme.shvms.in/live/watcher?inviterUid=u1&inviterName=Alex")!
        XCTAssertNil(LiveShareLink.parseSessionURL(watcherUrl))

        switch LiveShareLink.parse(url: watcherUrl) {
        case .watcherInvite(let invite):
            XCTAssertEqual(invite.inviterUid, "u1")
            XCTAssertEqual(invite.inviterName, "Alex")
        default:
            XCTFail("Expected watcherInvite, got \(String(describing: LiveShareLink.parse(url: watcherUrl)))")
        }
    }

    func testRejectsMalformedOrForeignLiveUrls() {
        XCTAssertNil(LiveShareLink.parse(url: URL(string: "https://evil.example.com/live/abc12345")!))
        XCTAssertNil(LiveShareLink.parse(url: URL(string: "https://trackme.shvms.in/live/ab")!))
        XCTAssertNil(LiveShareLink.parse(url: URL(string: "https://trackme.shvms.in/live/")!))
    }

    func testParsesPushNotificationFallbackWhenUrlStringAbsent() {
        let parsed = LiveShareLink.parse(
            urlString: nil,
            extraSessionId: "pushSess_42",
            extraType: "live_share_started",
            extraShareUrl: "https://trackme.shvms.in/live/pushSess_42"
        )
        XCTAssertEqual(parsed, .session("pushSess_42"))
    }

    // MARK: - LiveShareIntervals

    func testSerializeParseAndNormalizeMergeOverlapsAndClampBounds() {
        let intervals = [
            LiveShareInterval(startMillis: 2_000, endMillis: 5_000),
            LiveShareInterval(startMillis: 4_000, endMillis: 8_000),
            LiveShareInterval(startMillis: 10_000, endMillis: 15_000),
            LiveShareInterval(startMillis: 12_000, endMillis: 11_000) // invalid reversed
        ]

        let normalized = LiveShareIntervals.normalize(intervals, minStartMillis: 3_000, maxEndMillis: 14_000)
        XCTAssertEqual(normalized, [
            LiveShareInterval(startMillis: 3_000, endMillis: 8_000),
            LiveShareInterval(startMillis: 10_000, endMillis: 14_000)
        ])

        let json = LiveShareIntervals.serialize(normalized)
        XCTAssertNotNil(json)
        XCTAssertEqual(LiveShareIntervals.parse(json), normalized)
    }

    func testResolveModeReturnsFullPartialAndNilAccurately() {
        let rideStart: Int64 = 1_700_000_000_000
        let rideEnd: Int64 = rideStart + 1_000_000 // 1,000s

        // Empty -> nil
        XCTAssertNil(LiveShareIntervals.resolveMode(rideStartMillis: rideStart, rideEndMillis: rideEnd, intervals: []))

        // Within 20s tolerance at start and end -> FULL
        let fullByEdges = [
            LiveShareInterval(startMillis: rideStart + 15_000, endMillis: rideEnd - 15_000)
        ]
        XCTAssertEqual(
            LiveShareIntervals.resolveMode(rideStartMillis: rideStart, rideEndMillis: rideEnd, intervals: fullByEdges),
            LiveShareIntervals.modeFull
        )

        // Multi-toggle covering >= 90% -> FULL
        let fullByRatio = [
            LiveShareInterval(startMillis: rideStart, endMillis: rideStart + 450_000),
            LiveShareInterval(startMillis: rideStart + 500_000, endMillis: rideEnd)
        ]
        XCTAssertEqual(
            LiveShareIntervals.resolveMode(rideStartMillis: rideStart, rideEndMillis: rideEnd, intervals: fullByRatio),
            LiveShareIntervals.modeFull
        )

        // Mid-ride share -> PARTIAL
        let partial = [
            LiveShareInterval(startMillis: rideStart + 200_000, endMillis: rideStart + 600_000)
        ]
        XCTAssertEqual(
            LiveShareIntervals.resolveMode(rideStartMillis: rideStart, rideEndMillis: rideEnd, intervals: partial),
            LiveShareIntervals.modePartial
        )
    }

    func testContainsTimestampAndDateCheckInclusiveBounds() {
        let intervals = [LiveShareInterval(startMillis: 1_700_000_010_000, endMillis: 1_700_000_050_000)]
        XCTAssertTrue(LiveShareIntervals.containsTimestamp(intervals, timestampMillis: 1_700_000_010_000))
        XCTAssertTrue(LiveShareIntervals.containsDate(intervals, date: Date(timeIntervalSince1970: 1_700_000_030)))
        XCTAssertFalse(LiveShareIntervals.containsDate(intervals, date: Date(timeIntervalSince1970: 1_700_000_060)))
    }

    // MARK: - LiveShareIntervalTracker persistence

    func testIntervalTrackerPersistsAndRecoversAcrossProcessRestarts() {
        let suiteName = "LiveShareIntervalTrackerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rideId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let tracker1 = LiveShareIntervalTracker(defaults: defaults)
        tracker1.beginRide(rideId: rideId)
        tracker1.markLiveShareStarted(at: base.addingTimeInterval(10), activeRideId: rideId)
        tracker1.markLiveShareEnded(at: base.addingTimeInterval(120))
        tracker1.markLiveShareStarted(at: base.addingTimeInterval(300), activeRideId: rideId)

        // Simulate crash/re-launch by creating a brand new tracker bound to the same UserDefaults.
        let tracker2 = LiveShareIntervalTracker(defaults: defaults)
        let finalized = tracker2.finalizeIntervals(for: rideId, endedAt: base.addingTimeInterval(600))

        XCTAssertEqual(finalized, [
            LiveShareInterval(
                startMillis: Int64((base.addingTimeInterval(10).timeIntervalSince1970 * 1_000).rounded()),
                endMillis: Int64((base.addingTimeInterval(120).timeIntervalSince1970 * 1_000).rounded())
            ),
            LiveShareInterval(
                startMillis: Int64((base.addingTimeInterval(300).timeIntervalSince1970 * 1_000).rounded()),
                endMillis: Int64((base.addingTimeInterval(600).timeIntervalSince1970 * 1_000).rounded())
            )
        ])
    }

    // MARK: - LiveSessionViewerRepository.parseSnapshot

    func testParseSnapshotSupportsCoordinateArraysAndObjectsWithKmhToMpsConversion() throws {
        let json: [String: Any] = [
            "username": "Shubham",
            "status": "active",
            "lastLocation": [
                "lat": 12.9716,
                "lng": 77.5946,
                "speed": 36.0,
                "heading": 135.5,
                "batteryLevel": 82,
                "powerSaveMode": true,
                "timestamp": "2026-11-12T10:00:00Z"
            ],
            "path": [
                [12.9700, 77.5900],
                ["lat": 12.9716, "lon": 77.5946]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let snapshot = LiveSessionViewerRepository.parseSnapshot(sessionId: "sess_1234", data: data)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.username, "Shubham")
        XCTAssertTrue(snapshot?.isActive == true)
        XCTAssertEqual(snapshot?.path.count, 2)
        XCTAssertEqual(snapshot?.lastLocation?.speedKmh, 36.0)
        XCTAssertEqual(snapshot?.lastLocation?.speedMetersPerSecond ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.lastLocation?.headingDeg, 135.5)
        XCTAssertEqual(snapshot?.lastLocation?.batteryLevel, 82)
        XCTAssertEqual(snapshot?.lastLocation?.powerSaveMode, true)
    }

    func testParseSnapshotFallsBackToLastLocationWhenPathIsEmptyAndHandlesEndedStatus() throws {
        let json: [String: Any] = [
            "username": "Alex",
            "status": "ended",
            "stopReason": "Rider ended live sharing",
            "lastLocation": [
                "lat": 37.3323,
                "lon": -122.0312
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let snapshot = LiveSessionViewerRepository.parseSnapshot(sessionId: "sess_5678", data: data)
        XCTAssertEqual(snapshot?.isActive, false)
        XCTAssertEqual(snapshot?.stopReason, "Rider ended live sharing")
        XCTAssertEqual(snapshot?.path, [LiveViewerPoint(lat: 37.3323, lng: -122.0312)])
    }

    func testComputesFreshnessAgeAndFlagsDelayedUpdates() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let freshIso = formatter.string(from: now.addingTimeInterval(-12))
        let staleIso = formatter.string(from: now.addingTimeInterval(-50))
        let futureIso = formatter.string(from: now.addingTimeInterval(15))

        XCTAssertEqual(LiveSessionViewerRepository.ageSeconds(timestampIso: freshIso, now: now), 12)
        XCTAssertEqual(LiveSessionViewerRepository.ageSeconds(timestampIso: futureIso, now: now), 0)
        XCTAssertNil(LiveSessionViewerRepository.ageSeconds(timestampIso: "invalid-iso", now: now))

        XCTAssertFalse(LiveSessionViewerRepository.isDelayedUpdate(powerSaveMode: false, timestampIso: freshIso, now: now))
        XCTAssertTrue(LiveSessionViewerRepository.isDelayedUpdate(powerSaveMode: false, timestampIso: staleIso, now: now))
        XCTAssertTrue(LiveSessionViewerRepository.isDelayedUpdate(powerSaveMode: true, timestampIso: freshIso, now: now))
    }
}
