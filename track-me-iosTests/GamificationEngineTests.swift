import XCTest
@testable import track_me_ios

final class GamificationEngineTests: XCTestCase {

    private func loadVectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/home-gamification-v1.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid JSON format")
            throw URLError(.cannotDecodeRawData)
        }
        return json
    }

    func testLevelVectors() throws {
        let vectors = try loadVectors()
        guard let levels = vectors["levels"] as? [[String: Any]] else {
            XCTFail("Missing levels in vectors")
            return
        }

        for obj in levels {
            let duration = obj["duration_millis"] as! Int64
            let expectedLevel = obj["expected_level_id"] as! String

            let facts = GamificationFacts(lifetimeActivityCount: 0, lifetimeActiveDurationMillis: duration)
            let snapshot = GamificationEngine.deriveSnapshot(facts: facts)

            XCTAssertEqual(
                snapshot.currentLevelId,
                expectedLevel,
                "Failed for duration \(duration)"
            )
        }
    }

    func testMilestoneVectors() throws {
        let vectors = try loadVectors()
        guard let milestones = vectors["milestones"] as? [[String: Any]] else {
            XCTFail("Missing milestones in vectors")
            return
        }

        for obj in milestones {
            let count = obj["activity_count"] as! Int
            let expectedMilestone = obj["expected_milestone_id"] as! String

            let facts = GamificationFacts(lifetimeActivityCount: count, lifetimeActiveDurationMillis: 0)
            let snapshot = GamificationEngine.deriveSnapshot(facts: facts)

            if expectedMilestone == "milestone_none" {
                XCTAssertTrue(snapshot.unlockedMilestoneIds.isEmpty, "Expected no milestones for count \(count)")
            } else {
                XCTAssertTrue(
                    snapshot.unlockedMilestoneIds.contains(expectedMilestone),
                    "Expected milestone \(expectedMilestone) to be unlocked for count \(count), but was \(snapshot.unlockedMilestoneIds)"
                )
            }
        }
    }

    func testIdempotentOutput() {
        let facts = GamificationFacts(lifetimeActivityCount: 27, lifetimeActiveDurationMillis: 50_000_000)
        let snapshot1 = GamificationEngine.deriveSnapshot(facts: facts)
        let snapshot2 = GamificationEngine.deriveSnapshot(facts: facts)

        XCTAssertEqual(snapshot1, snapshot2)
    }

    func testDeletionRollback() {
        let baseFacts = GamificationFacts(lifetimeActivityCount: 25, lifetimeActiveDurationMillis: 36_000_000) // exactly level 3, milestone 25
        let snapshot = GamificationEngine.deriveSnapshot(facts: baseFacts)
        XCTAssertEqual(snapshot.currentLevelId, "level_3")
        XCTAssertTrue(snapshot.unlockedMilestoneIds.contains("milestone_25"))

        // Deletion simulating deleting a ride
        let reducedFacts = GamificationFacts(lifetimeActivityCount: 24, lifetimeActiveDurationMillis: 35_999_999)
        let rollbackSnapshot = GamificationEngine.deriveSnapshot(facts: reducedFacts)

        XCTAssertEqual(rollbackSnapshot.currentLevelId, "level_2")
        XCTAssertFalse(rollbackSnapshot.unlockedMilestoneIds.contains("milestone_25"))
        XCTAssertTrue(rollbackSnapshot.unlockedMilestoneIds.contains("milestone_10"))
    }

    func testMaxLevel() {
        let facts = GamificationFacts(lifetimeActivityCount: 100, lifetimeActiveDurationMillis: 540_000_000)
        let snapshot = GamificationEngine.deriveSnapshot(facts: facts)
        XCTAssertEqual(snapshot.currentLevelId, "level_6")
        XCTAssertNil(snapshot.nextLevelDurationThresholdMillis)
    }

    func testOverflowSafe() {
        let hugeFacts = GamificationFacts(lifetimeActivityCount: Int.max, lifetimeActiveDurationMillis: Int64.max)
        let snapshot = GamificationEngine.deriveSnapshot(facts: hugeFacts)
        XCTAssertEqual(snapshot.currentLevelId, "level_6")
        XCTAssertNil(snapshot.nextLevelDurationThresholdMillis)
        XCTAssertTrue(snapshot.unlockedMilestoneIds.contains("milestone_1000"))
    }

    func testDeterministicOrdering() {
        let facts = GamificationFacts(lifetimeActivityCount: 2000, lifetimeActiveDurationMillis: 0)
        let snapshot = GamificationEngine.deriveSnapshot(facts: facts)

        let expected = ["milestone_1", "milestone_10", "milestone_100", "milestone_1000", "milestone_25", "milestone_250", "milestone_50", "milestone_500"].sorted()
        XCTAssertEqual(snapshot.unlockedMilestoneIds, expected)
    }
}
