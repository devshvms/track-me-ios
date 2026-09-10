import XCTest
@testable import track_me_ios

final class GroupStartPolicyTests: XCTestCase {
    func testOnlyPreparingLeaderWithTwoMembersCanStart() {
        for status in [GroupSessionStatus.idle, .preparing, .live, .degraded, .ended] {
            for leader in [false, true] {
                for count in 0...5 {
                    var state = GroupSessionState()
                    state.status = status
                    state.isLeader = leader
                    state.roster = (0..<count).map {
                        GroupWire.RosterEntry(uid: "u\($0)", displayName: "Member",
                                              initials: "M", photoUrl: nil)
                    }
                    XCTAssertEqual(state.canStartGroup,
                                   leader && status == .preparing && count >= 2)
                }
            }
        }
    }

    func testRosterLeavingDisablesStartAgain() {
        var state = GroupSessionState()
        state.status = .preparing
        state.isLeader = true
        state.roster = ["leader", "guest"].map {
            GroupWire.RosterEntry(uid: $0, displayName: $0, initials: "M", photoUrl: nil)
        }
        XCTAssertTrue(state.canStartGroup)
        state.roster.removeLast()
        XCTAssertFalse(state.canStartGroup)
        XCTAssertTrue(state.isAloneInGroup)
    }

    func testServerRejectingLastSecondDepartureHasReadableBridgedError() {
        let error = GroupHttpError(statusCode: 409, code: "GROUP_OF_ONE", retryAfter: nil)
        XCTAssertEqual((error as NSError).localizedDescription,
                       LocalizationHelper.localized("Invite at least one other person before starting the group."))
    }

    func testUnknownAndMissingServerCodesNeverExposeSwiftErrorType() {
        for code: String? in [nil, "NEW_SERVER_ERROR"] {
            let error = GroupHttpError(statusCode: 503, code: code, retryAfter: nil)
            XCTAssertEqual(error.localizedDescription,
                           LocalizationHelper.localized("The group request could not be completed. Please try again."))
            XCTAssertFalse(error.localizedDescription.contains("GroupHttpError"))
        }
    }
}
