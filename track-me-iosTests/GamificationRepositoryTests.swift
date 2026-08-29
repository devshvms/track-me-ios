import XCTest
@testable import track_me_ios

@MainActor
final class GamificationRepositoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var repository: GamificationRepository!
    
    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "GamificationRepositoryTests.\(UUID().uuidString)")
        repository = GamificationRepository(defaults: defaults)
    }
    
    override func tearDown() {
        defaults.removePersistentDomain(forName: "GamificationRepositoryTests.\(UUID().uuidString)")
        super.tearDown()
    }
    
    private func createRide(durationMs: Int64, qualifies: Bool = true) -> Ride {
        let ride = Ride()
        ride.movingDurationMillis = durationMs
        ride.qualifiesForStats = qualifies
        return ride
    }

    func testLevelUpReveal() {
        // Initial state
        XCTAssertNil(repository.newLevelReveal)
        
        let rides = [createRide(durationMs: 125 * 60 * 1000)]
        repository.refresh(rides: rides)
        
        XCTAssertEqual(repository.newLevelReveal?.level, 2)
        XCTAssertEqual(repository.newLevelReveal?.name, "Moving")
        
        repository.acknowledgeNewLevel(repository.newLevelReveal!)
        
        XCTAssertNil(repository.newLevelReveal)
    }

    func testAchievementReveal() {
        XCTAssertTrue(repository.newAchievementsReveal.isEmpty)
        
        let ride1 = createRide(durationMs: 10 * 60 * 1000)
        repository.refresh(rides: [ride1])
        
        XCTAssertEqual(repository.newAchievementsReveal, ["First Qualifying Activity"])
        
        repository.acknowledgeAchievements(repository.newAchievementsReveal)
        XCTAssertTrue(repository.newAchievementsReveal.isEmpty)
        
        let rides = (0..<5).map { _ in createRide(durationMs: 10 * 60 * 1000) }
        repository.refresh(rides: rides)
        
        XCTAssertEqual(repository.newAchievementsReveal, ["Getting Moving"])
    }
}
