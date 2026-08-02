import XCTest
@testable import track_me_ios

final class RideStartAbortPolicyTests: XCTestCase {
    func testMatchingAbortConsumesPendingLaunch() {
        let token = UUID()
        var state = RideStartLaunchState()
        state.begin(token: token)

        XCTAssertTrue(state.abort(observedToken: token))
        XCTAssertNil(state.pendingToken)
    }

    func testStaleTokenCannotAbortOrCommitNewLaunch() {
        let staleToken = UUID()
        let currentToken = UUID()
        var state = RideStartLaunchState()
        state.begin(token: currentToken)

        XCTAssertFalse(state.abort(observedToken: staleToken))
        XCTAssertFalse(state.commit(observedToken: staleToken))
        XCTAssertEqual(state.pendingToken, currentToken)
        XCTAssertTrue(state.commit(observedToken: currentToken))
        XCTAssertNil(state.pendingToken)
    }

    func testResetClearsPendingLaunch() {
        var state = RideStartLaunchState()
        state.begin()
        state.reset()

        XCTAssertNil(state.pendingToken)
    }

    func testPostCommitUndoRequiresBothStrictThresholds() {
        XCTAssertTrue(RideStartAbortPolicy.canOfferPostCommitUndo(
            durationInMillis: 9_999,
            distanceMeters: 9.99
        ))
        XCTAssertFalse(RideStartAbortPolicy.canOfferPostCommitUndo(
            durationInMillis: RideStartAbortPolicy.postCommitWindowMillis,
            distanceMeters: 0
        ))
        XCTAssertFalse(RideStartAbortPolicy.canOfferPostCommitUndo(
            durationInMillis: 0,
            distanceMeters: RideStartAbortPolicy.postCommitDistanceMeters
        ))
    }

    func testTelemetryValuesMatchCrossPlatformContract() {
        XCTAssertEqual(RideStartAbortMethod.preCommit.rawValue, "pre_commit")
        XCTAssertEqual(RideStartAbortMethod.postCommitUndo.rawValue, "post_commit_undo")
    }
}
