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
        state.begin(awaitsPersonaChoice: true)
        state.reset()

        XCTAssertNil(state.pendingToken)
        XCTAssertFalse(state.awaitsPersonaChoice)
    }

    func testPersonaChoiceWindowDoesNotCommitWhenItLapses() {
        var state = RideStartLaunchState()
        let token = UUID()
        state.begin(token: token, awaitsPersonaChoice: true)

        XCTAssertTrue(state.awaitsPersonaChoice)
        XCTAssertTrue(state.isPending)
        XCTAssertEqual(RideStartAbortPolicy.personaChoiceWindow, .milliseconds(2_500))

        state.reset()
        XCTAssertFalse(state.isPending)
        XCTAssertFalse(state.awaitsPersonaChoice)
    }

    func testExplicitPersonaCommitClearsChoiceWindow() {
        var state = RideStartLaunchState()
        let token = UUID()
        state.begin(token: token, awaitsPersonaChoice: true)

        XCTAssertTrue(state.commit(observedToken: token))
        XCTAssertNil(state.pendingToken)
        XCTAssertFalse(state.awaitsPersonaChoice)
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

    func testPlainTapHonorsOnboardingPersonaPreselection() {
        XCTAssertEqual(
            RadialStartPersonaPolicy.selection(
                hovered: nil,
                didDrag: false,
                releasedInsideCenter: true,
                preselected: .cycling
            ),
            .cycling
        )
    }

    func testStopSliderRequiresSeventyFivePercentLeftwardTravel() {
        XCTAssertFalse(RideStopSliderPolicy.shouldStop(translation: -74.9, maxSlide: 100))
        XCTAssertTrue(RideStopSliderPolicy.shouldStop(translation: -75, maxSlide: 100))
        XCTAssertFalse(RideStopSliderPolicy.shouldStop(translation: 100, maxSlide: 100))
        XCTAssertFalse(RideStopSliderPolicy.shouldStop(translation: -100, maxSlide: 0))
    }
}
