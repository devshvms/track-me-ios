import XCTest
import SwiftData
@testable import track_me_ios

/// TASK-309 — the upgrade path nobody rehearses.
///
/// 1.8.7 removes `EmergencyContact` and `EmergencySettings` from the SwiftData schema. Every store
/// written by 1.6.5–1.8.6 therefore contains two entities the shipping model no longer describes,
/// and has to be migrated the first time an upgraded app opens it. That is exactly the kind of
/// change that is invisible in development — a simulator with no old store migrates nothing — and
/// catastrophic in production, because it happens on launch, before any UI exists to recover.
///
/// So this test writes a real store on disk using the *old* schema, closes it, and opens it again
/// with the shipping one. The legacy models below are deliberately redeclared here rather than
/// imported: the app no longer has them, which is the entire point, and SwiftData derives entity
/// names from the class name, so these produce a store byte-compatible with what 1.8.6 wrote.
@MainActor
final class ModelContainerUpgradeTests: XCTestCase {

    // MARK: - The deleted models, as 1.8.6 persisted them

    @Model final class EmergencyContact {
        var name: String
        var phoneNumber: String
        var medium: String
        var createdAt: Date

        init(name: String, phoneNumber: String, medium: String = "SMS", createdAt: Date = .now) {
            self.name = name
            self.phoneNumber = phoneNumber
            self.medium = medium
            self.createdAt = createdAt
        }
    }

    @Model final class EmergencySettings {
        var isSetupComplete: Bool
        var messageTemplate: String

        init(isSetupComplete: Bool = false, messageTemplate: String = "EMERGENCY! I need help.") {
            self.isSetupComplete = isSetupComplete
            self.messageTemplate = messageTemplate
        }
    }

    private var storeDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelContainerUpgradeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        storeURL = storeDirectory.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    // MARK: - Helpers

    /// The schema as it shipped in 1.6.5 through 1.8.6.
    private var legacySchema: Schema {
        Schema([
            Ride.self,
            GPSPoint.self,
            HomeDashboardIndex.self,
            EmergencyContact.self,
            EmergencySettings.self
        ])
    }

    private func container(for schema: Schema) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    /// Writes a store in the old shape: two rides, a point, and the emergency rows that 1.8.7
    /// deletes. Returns the id of a ride that must survive the upgrade.
    @discardableResult
    private func writeLegacyStore(rideCount: Int = 2) throws -> UUID {
        let legacy = try container(for: legacySchema)
        let context = legacy.mainContext

        var firstRideId: UUID!
        for index in 0..<rideCount {
            let ride = Ride(startTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600))
            ride.distanceMeters = 12_345
            ride.movingDurationMillis = 3_600_000
            context.insert(ride)
            if index == 0 { firstRideId = ride.id }
            context.insert(
                GPSPoint(
                    latitude: 37.3323 + Double(index) / 1000,
                    longitude: -122.0312,
                    altitude: 30,
                    accuracy: 5,
                    speed: 6.5,
                    timestamp: ride.startTime,
                    ride: ride
                )
            )
        }

        context.insert(EmergencyContact(name: "Legacy contact", phoneNumber: "+15550100"))
        context.insert(EmergencySettings(isSetupComplete: true))
        try context.save()
        return firstRideId
    }

    // MARK: - Tests

    func testAStoreWrittenBeforeTheEmergencyModelsWereRemovedStillOpens() throws {
        let survivingRideId = try writeLegacyStore()

        // The whole test. Before TASK-309 this line's production equivalent was followed by
        // `fatalError`, so a throw here was a launch crash for every upgrading rider.
        let upgraded = try container(for: ModelContainerFactory.schema)

        let rides = try upgraded.mainContext.fetch(FetchDescriptor<Ride>())
        XCTAssertEqual(rides.count, 2, "the upgrade must not lose ride history")
        XCTAssertTrue(
            rides.contains { $0.id == survivingRideId },
            "the specific ride written before the upgrade must still be there"
        )
        XCTAssertEqual(rides.first(where: { $0.id == survivingRideId })?.distanceMeters, 12_345)
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<GPSPoint>()).count, 2)
    }

    func testTheUpgradeIsIdempotentAcrossRelaunches() throws {
        try writeLegacyStore(rideCount: 1)

        // Migration happens once, but launches do not. A second and third open of the already
        // migrated store must be just as uneventful as the first.
        for launch in 1...3 {
            let container = try container(for: ModelContainerFactory.schema)
            XCTAssertEqual(
                try container.mainContext.fetch(FetchDescriptor<Ride>()).count, 1,
                "launch \(launch) changed the ride count"
            )
        }
    }

    func testAFreshInstallOpensTheSameSchemaWithNoLegacyStore() throws {
        // The other half of the matrix: nothing on disk at all. A migration that only works when
        // there is something to migrate would be a very silly way to break new installs.
        let fresh = try container(for: ModelContainerFactory.schema)
        XCTAssertEqual(try fresh.mainContext.fetch(FetchDescriptor<Ride>()).count, 0)
    }

    func testTheShippingSchemaNoLongerDescribesTheEmergencyEntities() {
        let names = Set(ModelContainerFactory.schema.entities.map(\.name))
        XCTAssertFalse(names.contains("EmergencyContact"))
        XCTAssertFalse(names.contains("EmergencySettings"))
        XCTAssertEqual(names, ["Ride", "GPSPoint", "HomeDashboardIndex"])
    }

    // MARK: - The fallback, for when the migration does not go to plan

    func testTheInMemoryFallbackIsAlwaysAvailable() {
        // `make()` degrades to this instead of trapping. If this could fail there would be no
        // fallback to degrade *to*, and the ladder would be one rung of nothing.
        let container = ModelContainerFactory.makeInMemory()
        XCTAssertEqual(container.schema.entities.count, 3)
    }

    func testAStoreFailureIsRememberedForCrashlyticsAndReportedOnlyOnce() {
        struct StoreUnavailable: Error {}
        let diagnostics = ModelContainerDiagnostics()

        XCTAssertNil(diagnostics.takeFailure(), "nothing to report before anything has failed")

        diagnostics.record(StoreUnavailable())
        XCTAssertTrue(diagnostics.takeFailure() is StoreUnavailable)
        XCTAssertNil(
            diagnostics.takeFailure(),
            "one launch failure is one report; repeating it on every foreground says nothing new"
        )
    }
}
