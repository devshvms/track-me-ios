import XCTest
@testable import track_me_ios

final class GroupTelemetryContractTests: XCTestCase {
    func testInviteSentHasNoProperties() {
        let event = GroupTelemetryContract.inviteSent()
        XCTAssertEqual(event.name, "group_invite_sent")
        XCTAssertNil(event.properties)
    }

    func testJoinEventsUseExactNamesKeysAndTypes() throws {
        let opened = GroupTelemetryContract.inviteOpened(viaCode: false)
        XCTAssertEqual(opened.name, "group_invite_opened")
        XCTAssertEqual(Set(opened.properties?.keys.map { $0 } ?? []), ["via_code"])
        XCTAssertNotNil(opened.properties?["via_code"] as? Bool)

        let joined = GroupTelemetryContract.memberJoined(memberCount: 3, viaCode: true)
        XCTAssertEqual(joined.name, "group_member_joined")
        XCTAssertEqual(Set(joined.properties?.keys.map { $0 } ?? []), ["member_count", "via_code"])
        XCTAssertNotNil(joined.properties?["member_count"] as? Int)
        XCTAssertNotNil(joined.properties?["via_code"] as? Bool)

        for reason in GroupJoinFailure.allCases {
            let failed = GroupTelemetryContract.joinFailed(reason: reason, viaCode: true)
            XCTAssertEqual(failed.name, "group_join_failed")
            XCTAssertEqual(Set(failed.properties?.keys.map { $0 } ?? []), ["reason", "via_code"])
            XCTAssertEqual(failed.properties?["reason"] as? String, reason.rawValue)
            XCTAssertNotNil(failed.properties?["via_code"] as? Bool)
        }
    }

    func testCounterAndMetaEventsUseExactTypes() {
        let removed = GroupTelemetryContract.memberRemoved(memberCount: 2)
        XCTAssertEqual(removed.name, "group_member_removed")
        XCTAssertEqual(Set(removed.properties?.keys.map { $0 } ?? []), ["member_count"])
        XCTAssertNotNil(removed.properties?["member_count"] as? Int)

        let meta = GroupTelemetryContract.metaUpdated(hasDestination: true, hasStartTime: false)
        XCTAssertEqual(meta.name, "group_meta_updated")
        XCTAssertEqual(Set(meta.properties?.keys.map { $0 } ?? []), ["has_destination", "has_start_time"])
        XCTAssertNotNil(meta.properties?["has_destination"] as? Bool)
        XCTAssertNotNil(meta.properties?["has_start_time"] as? Bool)
    }

    func testGroupTelemetryPropertyKeysContainNoPrivateData() {
        let forbidden = ["lat", "lng", "coordinate", "group_name", "uid", "member_id", "token", "join_code"]
        for event in GroupTelemetryContract.privacySamples {
            for key in event.properties?.keys.map({ $0 }) ?? [] {
                XCTAssertFalse(
                    forbidden.contains { key.localizedCaseInsensitiveContains($0) },
                    "\(event.name) must not include private property key \(key)"
                )
            }
        }
    }

    func testJoinFailureClassificationUsesClosedVocabulary() {
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupJoinClientError.malformedCode), .malformedCode)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupJoinClientError.expired), .expired)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupJoinClientError.signedOut), .signedOut)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupHttpError(statusCode: 409, code: "GROUP_FULL", retryAfter: nil)), .groupFull)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupHttpError(statusCode: 404, code: "GROUP_NOT_FOUND", retryAfter: nil)), .groupNotFound)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupHttpError(statusCode: 429, code: "JOIN_RATE_LIMITED", retryAfter: nil)), .joinRateLimited)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(URLError(.timedOut)), .network)
        XCTAssertEqual(GroupRideManager.classifyJoinFailure(GroupWire.Error.malformedResponse), .unknown)
    }

    func testInviteURLProvenanceAndTokenPrecedence() throws {
        let manager = GroupRideManager()
        let url = try XCTUnwrap(URL(string: "trackme://group?token=secret&code=ABC123"))

        XCTAssertTrue(manager.handleIncomingURL(url))
        XCTAssertEqual(manager.pendingJoinToken, "secret")
        XCTAssertNil(manager.pendingJoinCode)
        XCTAssertFalse(manager.pendingJoinViaCode)
    }

    func testEditingAReceivedCodeChangesTheJoinOriginToManual() throws {
        let manager = GroupRideManager()
        let url = try XCTUnwrap(URL(string: "trackme://group?code=ABC123"))
        XCTAssertTrue(manager.handleIncomingURL(url))

        manager.noteJoinCodeEdited("ABC123")
        XCTAssertFalse(manager.pendingJoinViaCode)

        manager.noteJoinCodeEdited("DEF456")
        XCTAssertTrue(manager.pendingJoinViaCode)
        XCTAssertNil(manager.pendingJoinCode)
        XCTAssertNil(manager.pendingJoinToken)
    }
}
