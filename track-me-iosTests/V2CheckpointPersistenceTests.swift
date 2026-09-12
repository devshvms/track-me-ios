import XCTest
import SwiftData
@testable import track_me_ios

@MainActor
final class V2CheckpointPersistenceTests: XCTestCase {
    func testDiskReopenPreservesV2CheckpointAndLegacyIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-checkpoint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rides.store")
        let id = try writeCheckpoint(to: url)
        let container = try makeContainer(url)
        let rides = try container.mainContext.fetch(FetchDescriptor<Ride>())
        let restored = try XCTUnwrap(rides.first { $0.id == id })
        XCTAssertEqual(restored.trackingAlgorithmVersion, 2)
        XCTAssertEqual(restored.aggregateSnapshot.distanceMeters, 477, accuracy: 0.001)
        XCTAssertEqual(restored.aggregateSnapshot.movingDurationMillis, 323_000)
        XCTAssertEqual(restored.points?.count, 1)
        XCTAssertEqual(try XCTUnwrap(restored.points?.first?.cumulativeDistanceMeters), 477, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.points?.first?.displayLatitude), 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.points?.first?.displayLongitude), 0.2, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(restored.points?.first).isPaused)
        XCTAssertNil(try XCTUnwrap(rides.first { $0.id != id }).trackingAlgorithmVersion)
    }

    private func makeContainer(_ url: URL) throws -> ModelContainer {
        let schema = Schema([Ride.self, GPSPoint.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    private func writeCheckpoint(to url: URL) throws -> UUID {
        let container = try makeContainer(url)
        let context = container.mainContext
        let ride = Ride()
        ride.trackingAlgorithmVersion = 2
        ride.applyAggregate(.live(distanceMeters: 477, movingDurationMillis: 323_000,
                                  maxSpeedMps: 2, pointCount: 1))
        context.insert(ride)
        let point = GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 5,
                             speed: 0, timestamp: Date(), isPaused: true, ride: ride)
        point.cumulativeDistanceMeters = 477
        point.displayLatitude = 0.1
        point.displayLongitude = 0.2
        context.insert(point)
        context.insert(Ride())
        try context.save()
        return ride.id
    }

    func testCloudDecodeRetainsV2MetadataAndLegacyFallback() throws {
        var payload: [String: Any] = [
            "startTime": Date(timeIntervalSince1970: 1_700_000_000),
            "trackingAlgorithmVersion": 2,
            "points": [["lat": 0.0, "lng": 0.0,
                        "timestamp": Date(timeIntervalSince1970: 1_700_000_001),
                        "cumulativeDistanceMeters": 477.0]]
        ]
        let ride = try XCTUnwrap(FirestoreSyncManager.parseRideDocument(docId: "v2-test", data: payload))
        XCTAssertEqual(ride.trackingAlgorithmVersion, 2)
        XCTAssertEqual(ride.points.first?.cumulativeDistanceMeters, 477)
        payload.removeValue(forKey: "trackingAlgorithmVersion")
        let legacy = try XCTUnwrap(FirestoreSyncManager.parseRideDocument(docId: "legacy-test", data: payload))
        XCTAssertNil(legacy.trackingAlgorithmVersion)
    }
}
