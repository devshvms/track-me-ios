import XCTest
import SwiftData
import FirebaseAuth
@testable import track_me_ios

@MainActor
final class DataRepositoryWipeTests: XCTestCase {
    var container: ModelContainer!
    var repository: DataRepository!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Ride.self, GPSPoint.self, configurations: config)
        repository = DataRepository()
        repository.setup(container: container)
    }

    func testWipeAllLocalData_clearsRidesAndPoints() async throws {
        // Arrange
        let context = container.mainContext

        for i in 1...3 {
            let ride = Ride(startTime: Date())
            ride.title = "Ride \(i)"
            context.insert(ride)

            for j in 1...5 {
                let point = GPSPoint(latitude: 10.0 + Double(j), longitude: 20.0, altitude: 0, accuracy: 5, speed: 10, timestamp: Date(), isPaused: false)
                ride.points?.append(point)
                context.insert(point)
            }
        }
        try context.save()

        let initialRides = try context.fetch(FetchDescriptor<Ride>())
        let initialPoints = try context.fetch(FetchDescriptor<GPSPoint>())

        XCTAssertEqual(initialRides.count, 3)
        XCTAssertEqual(initialPoints.count, 15)

        // Act
        try await repository.wipeAllLocalData()

        // Assert
        let finalRides = try context.fetch(FetchDescriptor<Ride>())
        let finalPoints = try context.fetch(FetchDescriptor<GPSPoint>())

        XCTAssertEqual(finalRides.count, 0)
        XCTAssertEqual(finalPoints.count, 0)
    }
}

final class RideStatsStoreResetTests: XCTestCase {
    var defaults: UserDefaults!
    var store: RideStatsStore!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "test_stats_store_\(UUID().uuidString)")
        store = RideStatsStore(defaults: defaults)
    }

    func testReset_clearsBlobAndCache() async throws {
        // Arrange
        let summary = GoodRideSummary(
            id: UUID(),
            distanceMeters: 5000,
            durationMillis: 1000 * 60 * 30,
            finishedAtMillis: 1000000,
            hasPoints: true
        )
        await store.recordGoodRide(summary)

        let statsAfterRide = await store.stats.value
        XCTAssertEqual(statsAfterRide.totalRides, 1)
        XCTAssertEqual(statsAfterRide.totalDistanceMeters, 5000)

        // Act
        await store.reset()

        // Assert
        let statsAfterReset = await store.stats.value
        XCTAssertEqual(statsAfterReset.totalRides, 0)
        XCTAssertEqual(statsAfterReset.totalDistanceMeters, 0)

        // Also verify the persisted blob is gone by instantiating a new store
        let newStore = RideStatsStore(defaults: defaults)
        let freshStats = await newStore.stats.value
        XCTAssertEqual(freshStats.totalRides, 0)
    }
}

final class AccountDeletionErrorMessageTests: XCTestCase {
    func testDeletionErrorMessage_requiresRecentLogin() {
        let error = NSError(domain: AuthErrorDomain, code: AuthErrorCode.requiresRecentLogin.rawValue, userInfo: nil)
        let message = AccountManagementView.deletionErrorMessage(for: error)
        // Test English fallback
        XCTAssertTrue(message.contains("sign out and sign back in"))
    }

    func testDeletionErrorMessage_genericError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        let message = AccountManagementView.deletionErrorMessage(for: error)
        XCTAssertTrue(message.contains("Couldn't delete your account"))
    }
}
