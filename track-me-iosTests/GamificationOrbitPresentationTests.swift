import XCTest
@testable import track_me_ios

final class GamificationOrbitPresentationTests: XCTestCase {
    func testRelativeProgressAndLevelIndex() {
        let snapshot = GamificationEngine.deriveSnapshot(
            facts: GamificationFacts(
                lifetimeActivityCount: 25,
                lifetimeActiveDurationMillis: 900 * 60_000
            )
        )

        XCTAssertEqual(GamificationOrbitPresentation.levelIndex(for: snapshot), 2)
        XCTAssertEqual(GamificationOrbitPresentation.progress(for: snapshot), 0.25, accuracy: 0.0001)
    }

    func testMaximumLevelRendersAsComplete() {
        let snapshot = GamificationEngine.deriveSnapshot(
            facts: GamificationFacts(
                lifetimeActivityCount: 1_000,
                lifetimeActiveDurationMillis: 9_000 * 60_000
            )
        )

        XCTAssertEqual(GamificationOrbitPresentation.levelIndex(for: snapshot), 5)
        XCTAssertEqual(GamificationOrbitPresentation.progress(for: snapshot), 1, accuracy: 0.0001)
    }

    func testProgressClampsMalformedPresentationInput() {
        let snapshot = malformedMidLevelSnapshot(denominator: 480)

        XCTAssertEqual(GamificationOrbitPresentation.progress(for: snapshot), 1, accuracy: 0.0001)
        XCTAssertEqual(
            GamificationOrbitPresentation.progress(for: malformedMidLevelSnapshot(denominator: 0)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GamificationOrbitPresentation.progress(for: malformedMidLevelSnapshot(denominator: -1)),
            0,
            accuracy: 0.0001
        )
    }

    private func malformedMidLevelSnapshot(denominator: Int64) -> GamificationSnapshot {
        GamificationSnapshot(
            currentLevelId: "level_2",
            currentLevelNameKey: "Moving",
            currentMinutes: 999,
            currentThresholdMinutes: 120,
            nextThresholdMinutes: 600,
            progressNumeratorMinutes: 900,
            progressDenominatorMinutes: denominator,
            latestUnlockedMilestoneId: nil,
            unlockedMilestoneIds: [],
            unlockedMilestoneCount: 0
        )
    }
}
