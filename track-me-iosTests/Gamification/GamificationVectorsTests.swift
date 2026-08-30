import XCTest
@testable import track_me_ios

struct GamificationVectors: Decodable {
    let levels: [LevelVector]
    let milestones: [MilestoneVector]
    let comparisons: [ComparisonVector]
    let snapshots: [SnapshotVector]
}

struct LevelVector: Decodable {
    let duration_millis: Int64
    let expected_level_id: String
}

struct MilestoneVector: Decodable {
    let activity_count: Int
    let expected_milestone_id: String
}

struct ComparisonVector: Decodable {
    let current_value: Int64
    let previous_value: Int64
    let expected_state: String
}

struct SnapshotVector: Decodable {
    let description: String
    let activities: [ActivityVector]
    let expected_snapshot: ExpectedSnapshot
}

struct ActivityVector: Decodable {
    let id: String
    let active_duration_millis: Int64
}

struct ExpectedSnapshot: Decodable {
    let active_duration_millis: Int64
    let activity_count: Int
    let level_id: String
    let level_name_key: String
    let current_minutes: Int64
    let current_threshold_minutes: Int64
    let next_threshold_minutes: Int64?
    let progress_numerator_minutes: Int64
    let progress_denominator_minutes: Int64
    let latest_milestone_id: String
    let unlocked_milestone_ids: [String]
    let unlocked_milestone_count: Int
}

final class GamificationVectorsTests: XCTestCase {
    
    func testDecodesCompleteGamificationVectorFileAccurately() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/home-gamification-v1.json")
            
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Vector file must exist")
        
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        
        let vectors = try decoder.decode(GamificationVectors.self, from: data)
        
        XCTAssertNotNil(vectors)
        
        let stressSnapshot = vectors.snapshots.first { $0.description == "5000 rows aggregation" }
        XCTAssertNotNil(stressSnapshot, "Must contain the 5000-row stress vector")
        XCTAssertEqual(stressSnapshot?.activities.count, 5000)
        
        let maxLevelSnapshot = vectors.snapshots.first { $0.description == "Max level overflow" }
        XCTAssertNotNil(maxLevelSnapshot)
        
        // Assert all expected_snapshot fields parsed
        for snapshot in vectors.snapshots {
            XCTAssertFalse(snapshot.expected_snapshot.level_name_key.isEmpty)
        }
    }
}
