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

        // Cross-checked with an independent spherical haversine, so the tolerance has to
        // absorb the sphere-vs-ellipsoid difference: the fixture measures with
        // CLLocation.distance (WGS84 geodesic), which reads ~0.075% longer over this
        // route — 6.5 m across 8.6 km. The old +/-1 m was calibrated for a 1.9 km
        // synthetic route where the two methods effectively agreed.
        XCTAssertEqual(routeDistance, OnboardingDemoFixture.distanceMeters, accuracy: routeDistance * 0.001)
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
        // The demo ride is a real recording (demo_ride.gpx) and the simulator scenario it
        // was captured against supplies no terrain, so every fix sits at 0 m. Asserted
        // explicitly rather than loosened, so a future re-recording that DOES carry
        // elevation trips this line instead of silently changing the demo.
        XCTAssertEqual(altitudeRange, 0, accuracy: 0.0001, "recorded scenario carries no elevation")
        // Recorded accuracy spans 5..50 m, wider than the old synthetic samples' tidy 3..8 m.
        XCTAssertTrue(points.allSatisfy { $0.speed > 0 && (3...60).contains($0.accuracy) })
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
