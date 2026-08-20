import SwiftData
import XCTest
@testable import track_me_ios

@MainActor
final class OnboardingDemoFixtureTests: XCTestCase {
    func testMakeRideBuildsCanonicalDetachedGraph() throws {
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = OnboardingDemoFixture.makeRide(
            startTime: startTime,
            title: "localized title"
        )
        let points = try XCTUnwrap(fixture.points?.sorted { $0.timestamp < $1.timestamp })

        XCTAssertEqual(fixture.startTime, startTime)
        XCTAssertEqual(fixture.endTime, startTime.addingTimeInterval(OnboardingDemoFixture.duration))
        XCTAssertEqual(fixture.title, "localized title")
        XCTAssertEqual(fixture.persona, RidePersona.cycling.rawValue)
        XCTAssertEqual(points.count, OnboardingDemoFixture.pointCount)
        XCTAssertTrue(points.allSatisfy { $0.ride === fixture })
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { pair in
            pair.0.timestamp < pair.1.timestamp
        })
        XCTAssertTrue(ChartAccessibility.signalGaps(points: points).isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(fixture.distanceMeters),
            OnboardingDemoFixture.distanceMeters,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.avgSpeedMps),
            OnboardingDemoFixture.averageSpeedMetersPerSecond,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.maxSpeedMps),
            OnboardingDemoFixture.maxSpeedMetersPerSecond,
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(fixture.pointCount), OnboardingDemoFixture.pointCount)
        XCTAssertNil(fixture.modelContext)
        XCTAssertTrue(points.allSatisfy { $0.modelContext == nil })
    }

    func testDetachedFixtureNeverAppearsInHistoryFetch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Ride.self,
            GPSPoint.self,
            configurations: configuration
        )
        let context = ModelContext(container)

        _ = OnboardingDemoFixture.makeRide()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Ride>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<GPSPoint>()).isEmpty)
    }

    func testRouteHasRealShapeAndMatchesStoredAggregate() throws {
        let fixture = OnboardingDemoFixture.makeRide()
        let points = try XCTUnwrap(fixture.points?.sorted { $0.timestamp < $1.timestamp })
        let routeDistance = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + haversineMeters(from: pair.0, to: pair.1)
        }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let altitudes = points.map(\.altitude)

        XCTAssertEqual(routeDistance, OnboardingDemoFixture.distanceMeters, accuracy: 1.0)
        let maxLatitude = try XCTUnwrap(latitudes.max())
        let minLatitude = try XCTUnwrap(latitudes.min())
        let maxLongitude = try XCTUnwrap(longitudes.max())
        let minLongitude = try XCTUnwrap(longitudes.min())
        let maxAltitude = try XCTUnwrap(altitudes.max())
        let minAltitude = try XCTUnwrap(altitudes.min())
        let latitudeRange = maxLatitude - minLatitude
        let longitudeRange = maxLongitude - minLongitude
        let altitudeRange = maxAltitude - minAltitude
        XCTAssertGreaterThan(latitudeRange, 0.004)
        XCTAssertGreaterThan(longitudeRange, 0.005)
        XCTAssertGreaterThanOrEqual(altitudeRange, 15)
        XCTAssertTrue(points.allSatisfy { $0.speed > 0 && (3...8).contains($0.accuracy) })
    }

    private func haversineMeters(from first: GPSPoint, to second: GPSPoint) -> Double {
        let firstLatitude = first.latitude * .pi / 180
        let secondLatitude = second.latitude * .pi / 180
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusMeters * 2 * asin(sqrt(haversine))
    }

    private let earthRadiusMeters = 6_371_000.0
}
