import XCTest
@testable import track_me_ios

final class LiveShareRequestTests: XCTestCase {
    func testLiveShareRequestSetsTimeout() {
        let url = URL(string: "https://example.com/x")!
        let req = LiveSharingManager.makeLiveShareRequest(url: url)
        XCTAssertEqual(req.timeoutInterval, 15, accuracy: 0.001)   // regression guard: never silently reverts to the 60s default
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTask382_StartAndStopRequestBodiesEnforceRiderConfirmedAssuranceGate() {
        let startWithAssurance = LiveSharingManager.buildStartRequestBody(
            durationMinutes: 30,
            username: "Rider",
            watcherUids: ["w1", "w2"],
            notifyWatchersOnEnd: true
        )
        XCTAssertEqual(startWithAssurance["notifyWatchersOnEnd"] as? Bool, true)

        let startNoAssurance = LiveSharingManager.buildStartRequestBody(
            durationMinutes: 30,
            username: "Rider",
            watcherUids: ["w1"],
            notifyWatchersOnEnd: false
        )
        XCTAssertEqual(startNoAssurance["notifyWatchersOnEnd"] as? Bool, false)

        let startEmptyWatchers = LiveSharingManager.buildStartRequestBody(
            durationMinutes: 30,
            username: "Rider",
            watcherUids: [],
            notifyWatchersOnEnd: true
        )
        XCTAssertNil(startEmptyWatchers["notifyWatchersOnEnd"])

        let confirmedStop = LiveSharingManager.buildStopRequestBody(
            reason: "Ride ended successfully.",
            stopKind: .riderConfirmed,
            notifyWatchersOnEnd: true,
            distanceKm: 12.4
        )
        XCTAssertEqual(confirmedStop["stopKind"] as? String, "rider_confirmed")
        XCTAssertEqual(confirmedStop["notifyWatchersOnEnd"] as? Bool, true)
        XCTAssertEqual(confirmedStop["distanceKm"] as? Double ?? 0, 12.4, accuracy: 0.001)

        let dwellStop = LiveSharingManager.buildStopRequestBody(
            reason: "Ride auto-ended.",
            stopKind: .autoDwellEnded,
            notifyWatchersOnEnd: true
        )
        XCTAssertEqual(dwellStop["stopKind"] as? String, "auto_dwell_ended")
        XCTAssertEqual(dwellStop["notifyWatchersOnEnd"] as? Bool, false)

        let expiredStop = LiveSharingManager.buildStopRequestBody(
            reason: "Share window elapsed.",
            stopKind: .expired,
            notifyWatchersOnEnd: true
        )
        XCTAssertEqual(expiredStop["stopKind"] as? String, "expired")
        XCTAssertEqual(expiredStop["notifyWatchersOnEnd"] as? Bool, false)

        XCTAssertEqual(TelemetryManager.bucketWatcherCount(0), "0")
        XCTAssertEqual(TelemetryManager.bucketWatcherCount(1), "1")
        XCTAssertEqual(TelemetryManager.bucketWatcherCount(2), "2_3")
        XCTAssertEqual(TelemetryManager.bucketWatcherCount(3), "2_3")
        XCTAssertEqual(TelemetryManager.bucketWatcherCount(4), "4_5")
        XCTAssertEqual(TelemetryManager.bucketWatcherCount(5), "4_5")

        let parsedEndedPush = LiveShareLink.parse(
            urlString: nil,
            extraSessionId: "pushSess_42",
            extraType: "live_share_ended",
            extraShareUrl: "https://trackme.shvms.in/live/pushSess_42"
        )
        XCTAssertEqual(parsedEndedPush, .session("pushSess_42"))
    }
}
