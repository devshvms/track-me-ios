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
        XCTAssertNil(snapshot.nextThresholdMinutes)
        XCTAssertEqual(snapshot.currentMinutes, 9_000)
        XCTAssertEqual(snapshot.currentThresholdMinutes, 9_000)
        XCTAssertEqual(snapshot.progressNumeratorMinutes, 0)
        XCTAssertEqual(snapshot.progressDenominatorMinutes, 0)
    }

    func testOverflowSafe() {
        let hugeFacts = GamificationFacts(lifetimeActivityCount: Int.max, lifetimeActiveDurationMillis: Int64.max)
        let snapshot = GamificationEngine.deriveSnapshot(facts: hugeFacts)
        XCTAssertEqual(snapshot.currentLevelId, "level_6")
        XCTAssertNil(snapshot.nextThresholdMinutes)
        XCTAssertTrue(snapshot.unlockedMilestoneIds.contains("milestone_1000"))
    }

    func testDeterministicOrdering() {
        let facts = GamificationFacts(lifetimeActivityCount: 2000, lifetimeActiveDurationMillis: 0)
        let snapshot = GamificationEngine.deriveSnapshot(facts: facts)

        let expected = [
            "milestone_1", "milestone_10", "milestone_25", "milestone_50",
            "milestone_100", "milestone_250", "milestone_500", "milestone_1000"
        ]
        XCTAssertEqual(snapshot.unlockedMilestoneIds, expected)
        XCTAssertEqual(snapshot.latestUnlockedMilestoneId, "milestone_1000")
    }

    func testProgressIsRelativeToCurrentLevel() {
        let snapshot = GamificationEngine.deriveSnapshot(facts: GamificationFacts(
            lifetimeActivityCount: 25,
            lifetimeActiveDurationMillis: 650 * 60_000
        ))

        XCTAssertEqual(snapshot.currentLevelId, "level_3")
        XCTAssertEqual(snapshot.currentLevelNameKey, "Regular")
        XCTAssertEqual(snapshot.currentThresholdMinutes, 600)
        XCTAssertEqual(snapshot.nextThresholdMinutes, 1_800)
        XCTAssertEqual(snapshot.progressNumeratorMinutes, 50)
        XCTAssertEqual(snapshot.progressDenominatorMinutes, 1_200)
    }

    func testCompleteSnapshotVectorsMatchFrozenContract() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/home-gamification-v1.json")
        let vectors = try JSONDecoder().decode(
            GamificationVectors.self,
            from: Data(contentsOf: fileURL)
        )

        for vector in vectors.snapshots {
            let totalDuration = vector.activities.reduce(Int64(0)) {
                $0 + $1.active_duration_millis
            }
            let snapshot = GamificationEngine.deriveSnapshot(facts: GamificationFacts(
                lifetimeActivityCount: vector.activities.count,
                lifetimeActiveDurationMillis: totalDuration
            ))
            let expected = vector.expected_snapshot

            XCTAssertEqual(totalDuration, expected.active_duration_millis, vector.description)
            XCTAssertEqual(vector.activities.count, expected.activity_count, vector.description)
            XCTAssertEqual(snapshot.currentLevelId, expected.level_id, vector.description)
            XCTAssertEqual(snapshot.currentLevelNameKey, expected.level_name_key, vector.description)
            XCTAssertEqual(snapshot.currentMinutes, expected.current_minutes, vector.description)
            XCTAssertEqual(snapshot.currentThresholdMinutes, expected.current_threshold_minutes, vector.description)
            XCTAssertEqual(snapshot.nextThresholdMinutes, expected.next_threshold_minutes, vector.description)
            XCTAssertEqual(snapshot.progressNumeratorMinutes, expected.progress_numerator_minutes, vector.description)
            XCTAssertEqual(snapshot.progressDenominatorMinutes, expected.progress_denominator_minutes, vector.description)
            XCTAssertEqual(
                snapshot.latestUnlockedMilestoneId ?? "milestone_none",
                expected.latest_milestone_id,
                vector.description
            )
            XCTAssertEqual(snapshot.unlockedMilestoneIds, expected.unlocked_milestone_ids, vector.description)
            XCTAssertEqual(snapshot.unlockedMilestoneCount, expected.unlocked_milestone_count, vector.description)
        }
    }
}
