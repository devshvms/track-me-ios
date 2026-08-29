import XCTest
@testable import track_me_ios

final class GamificationEngineTests: XCTestCase {

    private func createRide(
        durationMs: Int64 = 300_000,
        qualifies: Bool = true,
        isSample: Bool = false,
        pendingDelete: Bool = false,
        wasGroup: Bool = false,
        groupCount: Int? = nil,
        persona: String = "CYCLING",
        distance: Double = 1000.0
    ) -> Ride {
        let ride = Ride()
        ride.movingDurationMillis = durationMs
        ride.qualifiesForStats = qualifies
        ride.isSample = isSample
        ride.pendingDelete = pendingDelete
        ride.wasGroupRide = wasGroup
        ride.groupRiderCount = groupCount
        ride.persona = persona
        ride.distanceMeters = distance
        return ride
    }

    func testRideQualificationRules() {
        // Valid
        XCTAssertTrue(GamificationEngine.isQualifyingRide(createRide()))
        
        // Invalid: sample
        XCTAssertFalse(GamificationEngine.isQualifyingRide(createRide(isSample: true)))
        
        // Invalid: deleted
        XCTAssertFalse(GamificationEngine.isQualifyingRide(createRide(pendingDelete: true)))
        
        // Invalid: < 5 mins
        XCTAssertFalse(GamificationEngine.isQualifyingRide(createRide(durationMs: 299_000)))
        
        // Invalid: doesn't qualify for stats
        XCTAssertFalse(GamificationEngine.isQualifyingRide(createRide(qualifies: false)))
    }

    func testGroupRideQualificationRules() {
        XCTAssertFalse(GamificationEngine.isQualifyingGroupRide(createRide(wasGroup: true, groupCount: 1)))
        XCTAssertTrue(GamificationEngine.isQualifyingGroupRide(createRide(wasGroup: true, groupCount: 2)))
        XCTAssertFalse(GamificationEngine.isQualifyingGroupRide(createRide(wasGroup: false)))
    }

    func testLevelsDerivation() {
        let level1Rides = [createRide(durationMs: 60 * 60 * 1000)] // 60 mins -> Starter
        XCTAssertEqual(GamificationEngine.calculateLevel(from: level1Rides).name, "Starter")

        let level2Rides = [createRide(durationMs: 125 * 60 * 1000)] // 125 mins -> Moving
        XCTAssertEqual(GamificationEngine.calculateLevel(from: level2Rides).name, "Moving")
        
        let level5Rides = [createRide(durationMs: 4501 * 60 * 1000)] // 4501 mins -> Enduring
        XCTAssertEqual(GamificationEngine.calculateLevel(from: level5Rides).name, "Enduring")
    }

    func testAchievementUnlocks() {
        var rides = [Ride]()
        
        // 1st ride
        rides.append(createRide())
        var achievements = GamificationEngine.getUnlockedAchievements(from: rides)
        XCTAssertTrue(achievements.contains("First Qualifying Activity"))
        XCTAssertFalse(achievements.contains("Getting Moving"))

        // Add 4 more rides (total 5)
        for _ in 0..<4 {
            rides.append(createRide(persona: "RUNNING"))
        }
        achievements = GamificationEngine.getUnlockedAchievements(from: rides)
        XCTAssertTrue(achievements.contains("Getting Moving"))
        
        // Multi-Move requires 3 distinct personas
        rides.append(createRide(persona: "WALKING"))
        achievements = GamificationEngine.getUnlockedAchievements(from: rides)
        XCTAssertTrue(achievements.contains("Multi-Move"))
        
        // Add a group ride with 11 people
        rides.append(createRide(wasGroup: true, groupCount: 11, distance: 100000.0))
        achievements = GamificationEngine.getUnlockedAchievements(from: rides)
        XCTAssertTrue(achievements.contains("Together"))
        XCTAssertTrue(achievements.contains("Full Crew"))
        XCTAssertTrue(achievements.contains("Distance Together"))
    }
}
