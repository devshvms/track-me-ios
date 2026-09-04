import XCTest
@testable import track_me_ios

/// TASK-289 — the empty-member state drives the invite prompt, so it is worth a test.
///
/// The iOS half of `GroupInvitePromptStateTest` on Android; the two assert the same rules against
/// the same predicate so the platforms cannot drift. 42 people created a group and 2 sent an
/// invite: wrong-false hides the prompt from exactly the person who needs it, and wrong-true nags a
/// group that is already full.
final class GroupInvitePromptStateTests: XCTestCase {

    private func rosterEntry(_ uid: String) -> GroupWire.RosterEntry {
        GroupWire.RosterEntry(
            uid: uid,
            displayName: uid,
            initials: String(uid.prefix(1)).uppercased(),
            photoUrl: nil
        )
    }

    private func state(isLeader: Bool, roster: [String]) -> GroupSessionState {
        var s = GroupSessionState()
        s.status = .preparing
        s.groupId = "g1"
        s.joinCode = "ABC123"
        s.isLeader = isLeader
        s.roster = roster.map(rosterEntry)
        return s
    }

    func testLeaderAloneSeesTheInvitePrompt() {
        XCTAssertTrue(state(isLeader: true, roster: ["leader"]).isAloneInGroup)
    }

    func testEmptyRosterStillCountsAsAlone() {
        // The roster arrives asynchronously, so the leader can briefly see zero members. Showing
        // the prompt there is right: they are, in fact, the only one in the group.
        XCTAssertTrue(state(isLeader: true, roster: []).isAloneInGroup)
    }

    func testPromptDisappearsTheMomentSomeoneJoins() {
        XCTAssertFalse(state(isLeader: true, roster: ["leader", "guest"]).isAloneInGroup)
    }

    func testJoinerWaitingAloneIsNotPromptedToInvite() {
        // Only the leader owns the invite. A member who joined by code and happens to be looking at
        // a roster of one must not be told to invite people to someone else's group.
        XCTAssertFalse(state(isLeader: false, roster: ["guest"]).isAloneInGroup)
    }

    func testMatchesAndroidAcrossTheSameTable() {
        // Same table as GroupInvitePromptStateTest.kt. Parity is the point: the two platforms show
        // the same prompt in the same circumstances, per the contract's "same copy, same trigger".
        let cases: [(isLeader: Bool, members: Int, expected: Bool)] = [
            (true, 0, true),
            (true, 1, true),
            (true, 2, false),
            (true, 5, false),
            (false, 0, false),
            (false, 1, false),
            (false, 2, false),
        ]
        for c in cases {
            let roster = (0..<c.members).map { "u\($0)" }
            XCTAssertEqual(
                state(isLeader: c.isLeader, roster: roster).isAloneInGroup,
                c.expected,
                "isLeader=\(c.isLeader) members=\(c.members)"
            )
        }
    }
}
