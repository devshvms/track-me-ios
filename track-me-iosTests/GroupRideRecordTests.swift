import XCTest
@testable import track_me_ios

/// TASK-232 / COMMUNITY_REDESIGN_SPEC §5. The acceptance criteria with teeth are about what is
/// *not* stored, so they are asserted here rather than left to review. Mirrors Android's
/// `GroupRideRecordTest`.
final class GroupRideRecordTests: XCTestCase {

    func testASoloRideCarriesNoGroupRecord() {
        let ride = Ride(startTime: Date())
        XCTAssertFalse(ride.wasGroupRide)
        XCTAssertNil(ride.groupRiderCount)
    }

    func testAnUnobservedGroupSizeRendersNoCountRatherThanZero() {
        // §5.5, the same honesty rule as HISTORY_DETAIL_REDESIGN_SPEC §5.2: absent is absent.
        let ride = Ride(startTime: Date())
        ride.wasGroupRide = true
        ride.groupRiderCount = nil
        XCTAssertTrue(ride.wasGroupRide)
        XCTAssertNil(ride.groupRiderCount)
    }

    func testTheGroupFieldsAreNotInTheFirestoreFieldMap() {
        // §5.4: no new sync path, no new Data Safety surface. FirestoreSyncManager writes an
        // explicit map, so this holds only as long as nobody adds them to it.
        let source = Self.read("Services/FirestoreSyncManager.swift")
        XCTAssertFalse(source.contains("wasGroupRide"))
        XCTAssertFalse(source.contains("groupRiderCount"))
    }

    func testCommunityReadsLocalRideRecordsAndJoinsNothing() {
        // Scoped to the group-rides fetch, not the whole file: the *live* roster legitimately
        // renders member names while a group is running, and §4 leaves that untouched. The
        // criterion is about what is stored and queried, which is where the promise lives.
        let source = Self.read("Views/GroupRide/CommunityView.swift")
        guard let range = source.range(of: "private func loadGroupRides()"),
              let end = source.range(of: "groupRides = (try?", range: range.upperBound..<source.endIndex) else {
            XCTFail("loadGroupRides not found")
            return
        }
        let query = String(source[range.lowerBound..<end.upperBound])

        XCTAssertTrue(query.contains("wasGroupRide"), "the query must filter on the marker")
        XCTAssertTrue(query.contains("pendingDelete"), "deleted rides must be excluded")
        XCTAssertTrue(query.contains("propertiesToFetch"), "route points must stay out of the fetch")
        // A count is the maximum: the projection has nowhere to put anyone's identity.
        XCTAssertFalse(query.contains("displayName"))
        XCTAssertFalse(query.contains("roster"))
        XCTAssertFalse(query.contains("points"))
    }

    func testTheGroupRideCardCarriesACountAndNeverAName() {
        // §5.3. Community passes exactly one extra fact to the shared History card.
        let source = Self.read("Views/GroupRide/CommunityView.swift")
        XCTAssertTrue(source.contains("trailingLabel: summary.groupRiderCount.map"))
        XCTAssertFalse(source.contains("trailingLabel: summary.title"))
    }

    private static func read(_ relative: String) -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("track-me-ios")
                .appendingPathComponent(relative)
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return text }
        }
        XCTFail("\(relative) not found from \(#filePath)")
        return ""
    }
}
