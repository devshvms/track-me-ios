import XCTest
@testable import track_me_ios

/// TASK-276: the geometry that decides what the rider is told about their position.
/// Mirrors the Android suite; both platforms run the same arithmetic on the same curve.
final class GamificationTrailTests: XCTestCase {

    private func snapshot(minutes: Int64, activities: Int = 1) -> GamificationSnapshot {
        GamificationEngine.deriveSnapshot(
            facts: GamificationFacts(
                lifetimeActivityCount: activities,
                lifetimeActiveDurationMillis: minutes * 60_000
            )
        )
    }

    func testProgressIsMeasuredWithinTheLevelNotAgainstTheNextThreshold() {
        // 257 minutes is level 2 (120) heading for level 3 (600): 137 of 480, not 257 of 600.
        let s = snapshot(minutes: 257)
        XCTAssertEqual(GamificationTrail.levelIndex(for: s), 1)
        XCTAssertEqual(GamificationTrail.progressWithinLevel(s), 137.0 / 480.0, accuracy: 0.0001)
    }

    func testTheMaximumLevelReadsAsComplete() {
        let s = snapshot(minutes: 9_000)
        XCTAssertEqual(GamificationTrail.levelIndex(for: s), GamificationEngine.levels.count - 1)
        XCTAssertEqual(GamificationTrail.progressWithinLevel(s), 1, accuracy: 0.0001)
    }

    func testAMalformedDenominatorBelowTheTopReadsAsZeroNotAsFinished() {
        let malformed = GamificationSnapshot(
            currentLevelId: "level_2",
            currentLevelNameKey: "Moving",
            currentMinutes: 257,
            currentActivityCount: 18,
            currentThresholdMinutes: 120,
            nextThresholdMinutes: 600,
            progressNumeratorMinutes: 137,
            progressDenominatorMinutes: 0,
            latestUnlockedMilestoneId: nil,
            unlockedMilestoneIds: [],
            unlockedMilestoneCount: 0
        )
        XCTAssertEqual(GamificationTrail.progressWithinLevel(malformed), 0, accuracy: 0.0001)
    }

    func testTheMarkerSitsBetweenItsLevelAndTheNextNeverBeyond() {
        let s = snapshot(minutes: 257)
        let here = GamificationTrail.fraction(forLevel: 1)
        let next = GamificationTrail.fraction(forLevel: 2)
        let marker = GamificationTrail.markerFraction(s)
        XCTAssertGreaterThan(marker, here)
        XCTAssertLessThan(marker, next)
    }

    func testABrandNewRiderStartsAtTheFootOfTheTrail() {
        XCTAssertEqual(GamificationTrail.markerFraction(snapshot(minutes: 0, activities: 0)), 0, accuracy: 0.0001)
    }

    func testTheMaximumLevelPutsTheMarkerAtTheSummit() {
        XCTAssertEqual(GamificationTrail.markerFraction(snapshot(minutes: 12_000)), 1, accuracy: 0.0001)
    }

    func testEveryLevelGetsOneNodeTaggedByState() {
        let nodes = GamificationTrail.nodes(snapshot(minutes: 257))
        XCTAssertEqual(nodes.count, GamificationEngine.levels.count)
        XCTAssertEqual(nodes[0].state, .passed)
        XCTAssertEqual(nodes[1].state, .current)
        XCTAssertEqual(nodes[2].state, .ahead)
        XCTAssertEqual(nodes.map(\.levelId), GamificationEngine.levels.map(\.id))
    }

    func testNodesStayInsideTheDrawingBox() {
        // A waypoint outside the box would clip its own number, which is how the radial version
        // lost half of every lock icon.
        for node in GamificationTrail.nodes(snapshot(minutes: 257)) {
            XCTAssertTrue((0...GamificationTrail.width).contains(node.position.x))
            XCTAssertTrue((0...GamificationTrail.height).contains(node.position.y))
        }
    }

    func testTheCardIsPlacedOnWhicheverSideThePathIsNotUsing() {
        for node in GamificationTrail.nodes(snapshot(minutes: 257)) {
            XCTAssertEqual(node.position.x < GamificationTrail.width / 2, node.cardOnRight)
        }
    }

    func testTheTrailClimbs() {
        let nodes = GamificationTrail.nodes(snapshot(minutes: 257))
        for (lower, higher) in zip(nodes, nodes.dropFirst()) {
            XCTAssertLessThan(higher.position.y, lower.position.y,
                              "level \(higher.levelIndex) is not above \(lower.levelIndex)")
        }
    }

    /// The parity assertion that matters: both platforms place the marker at the same fraction.
    func testMarkerFractionMatchesTheAndroidValueForTheSameSnapshot() {
        // Android's GamificationTrailTest asserts 0.2 + 0.285416… * 0.2 for 257 minutes.
        let expected = 0.2 + (137.0 / 480.0) * 0.2
        XCTAssertEqual(Double(GamificationTrail.markerFraction(snapshot(minutes: 257))),
                       expected, accuracy: 0.0001)
    }
}
