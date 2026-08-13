import XCTest
@testable import track_me_ios

final class GroupStatusAlertPolicyTests: XCTestCase {
    private let needHelp = RiderStatusCodec.parse("1GNH")!
    private let crashed = RiderStatusCodec.parse("1GCR")!
    private let tired = RiderStatusCodec.parse("3GTI")!

    func testNewFreshAlertFiresOnceAndCreatesLedger() {
        let current = [member("ravi", needHelp)]
        let first = decide(previous: [], current: current)
        XCTAssertEqual(first.alerts, [.init(uid: "ravi", status: needHelp)])
        XCTAssertEqual(first.ledger, ["ravi": "1GNH"])

        let repeated = decide(
            previous: current,
            current: current,
            ledger: first.ledger
        )
        XCTAssertTrue(repeated.alerts.isEmpty)
        XCTAssertEqual(repeated.ledger, first.ledger)
    }

    func testJoinWindowStalePositionAndMuteSuppressEntry() {
        let current = [member("ravi", needHelp)]
        XCTAssertTrue(decide(previous: [], current: current, elapsedSinceJoin: 59_999).alerts.isEmpty)
        XCTAssertTrue(decide(previous: [], current: current, freshUIDs: []).alerts.isEmpty)
        XCTAssertTrue(decide(previous: [], current: current, muted: true).alerts.isEmpty)
    }

    func testAlertCodeTransitionCanAlertAgain() {
        let result = decide(
            previous: [member("ravi", needHelp)],
            current: [member("ravi", crashed)],
            ledger: ["ravi": needHelp.raw]
        )
        XCTAssertEqual(result.alerts, [.init(uid: "ravi", status: crashed)])
        XCTAssertEqual(result.ledger, ["ravi": crashed.raw])
    }

    func testLeavingAlertResolvesOnlyAStatusThatWasShown() {
        let resolution = decide(
            previous: [member("ravi", needHelp)],
            current: [member("ravi", tired)],
            ledger: ["ravi": needHelp.raw]
        )
        XCTAssertEqual(resolution.resolutions, [.init(uid: "ravi", status: needHelp)])
        XCTAssertTrue(resolution.ledger.isEmpty)

        let neverShown = decide(
            previous: [member("ravi", needHelp)],
            current: [member("ravi", tired)]
        )
        XCTAssertTrue(neverShown.resolutions.isEmpty)
    }

    func testMuteSuppressesResolutionAndConsumesItsLedger() {
        let result = decide(
            previous: [member("ravi", needHelp)],
            current: [],
            ledger: ["ravi": needHelp.raw],
            muted: true
        )
        XCTAssertTrue(result.resolutions.isEmpty)
        XCTAssertTrue(result.ledger.isEmpty)
    }

    private func decide(
        previous: [GroupWire.MemberStatus],
        current: [GroupWire.MemberStatus],
        freshUIDs: Set<String> = ["ravi"],
        ledger: [String: String] = [:],
        elapsedSinceJoin: Int64 = 60_000,
        muted: Bool = false
    ) -> GroupStatusAlertPolicy.Decision {
        GroupStatusAlertPolicy.evaluate(
            previous: previous,
            current: current,
            freshUIDs: freshUIDs,
            shownLedger: ledger,
            elapsedSinceJoinMillis: elapsedSinceJoin,
            alertsMuted: muted
        )
    }

    private func member(_ uid: String, _ status: RiderStatus) -> GroupWire.MemberStatus {
        .init(
            uid: uid,
            status: status,
            serverTsMillis: 0,
            ageAnchor: .init(ageAtReceiptMillis: 0, receivedAtElapsedMillis: 0, isKnown: true)
        )
    }
}
