import XCTest
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
}
