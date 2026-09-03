import CryptoKit
import Foundation
import XCTest
@testable import track_me_ios

final class TrackingV2ReplayFixtureTests: XCTestCase {
    func testSharedSyntheticReplayVectorsSatisfyV2Invariants() throws {
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(data.sha256, fixtureSHA256)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\"latitude\""))
        XCTAssertFalse(text.contains("\"longitude\""))
        XCTAssertFalse(text.contains("\"routeTitle\""))

        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.coordinateSpace, "synthetic_local_metres")
        XCTAssertGreaterThanOrEqual(fixture.scenarios.count, 6)

        for encoded in fixture.scenarios {
            let scenario = try encoded.makeScenario()
            let result = TrackingV2ReplayHarness.run(scenario)
            let expected = encoded.expected

            XCTAssertGreaterThanOrEqual(result.distanceMeters, expected.distanceMinMeters, encoded.id)
            XCTAssertLessThanOrEqual(result.distanceMeters, expected.distanceMaxMeters, encoded.id)
            XCTAssertEqual(result.movementState.rawValue, expected.finalState, encoded.id)
            XCTAssertGreaterThanOrEqual(result.routeSegments.count, expected.routeSegmentsMin, encoded.id)
            XCTAssertLessThanOrEqual(result.routeSegments.count, expected.routeSegmentsMax, encoded.id)
            XCTAssertEqual(result.sampleCount, expected.sampleCount, encoded.id)
            XCTAssertEqual(result.missingSpeedCount, expected.missingSpeedCount, encoded.id)
            XCTAssertEqual(result.degradedSampleCount, expected.degradedSampleCount, encoded.id)
            XCTAssertEqual(result.rejectedOutlierCount, expected.rejectedOutlierCount, encoded.id)
            XCTAssertEqual(result.detectedStepCount, expected.detectedStepCount, encoded.id)
            XCTAssertTrue(result.isPostProcessed, encoded.id)
        }
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tracking-v2-replay-v1.json")
    }

    private let fixtureSHA256 = "bf135313375b5e499faa0be543d6181ac13216a5d375cd7dc021c86f5ea2b082"
}

private extension TrackingV2ReplayFixtureTests {
    struct Fixture: Decodable {
        let schemaVersion: Int
        let coordinateSpace: String
        let scenarios: [EncodedScenario]
    }

    struct EncodedScenario: Decodable {
        let id: String
        let persona: String
        let events: [EncodedEvent]
        let expected: Expectation

        func makeScenario() throws -> TrackingV2ReplayScenario {
            let decodedPersona = try required(RidePersona(rawValue: persona), "Unknown persona \(persona)")
            let decodedEvents = try events.map { event -> TrackingV2ReplayEvent in
                switch event.kind {
                case "discontinuity":
                    return .discontinuity
                case "sample":
                    return .sample(try event.makeSample(persona: decodedPersona))
                default:
                    throw FixtureError.invalidValue("Unknown event kind \(event.kind) in \(id)")
                }
            }
            return TrackingV2ReplayScenario(id: id, persona: decodedPersona, events: decodedEvents)
        }
    }

    struct EncodedEvent: Decodable {
        let kind: String
        let elapsedMillis: Int64?
        let eastMeters: Double?
        let northMeters: Double?
        let accuracyMeters: Float?
        let gpsSpeedMps: Float?
        let gpsSpeedAccuracyMps: Float?
        let motionEnergy: Float?
        let motionAgeMillis: Int64?
        let steps: Int64?
        let stepAgeMillis: Int64?
        let cadenceHz: Float?
        let powerMode: String?

        func makeSample(persona: RidePersona) throws -> TrackingV2Sample {
            let east = try required(eastMeters, "Missing eastMeters")
            let north = try required(northMeters, "Missing northMeters")
            let modeName = try required(powerMode, "Missing powerMode")
            let mode = try required(TrackingV2PowerMode(rawValue: modeName), "Unknown powerMode \(modeName)")
            return TrackingV2Sample(
                latitude: syntheticBaseLatitude + north / metresPerDegree,
                longitude: syntheticBaseLongitude + east
                    / (metresPerDegree * cos(syntheticBaseLatitude * .pi / 180)),
                horizontalAccuracyMeters: try required(accuracyMeters, "Missing accuracyMeters"),
                elapsedRealtimeMillis: try required(elapsedMillis, "Missing elapsedMillis"),
                gpsSpeedMetersPerSecond: gpsSpeedMps,
                gpsSpeedAccuracyMetersPerSecond: gpsSpeedAccuracyMps,
                motionEnergyMetersPerSecondSquared: motionEnergy,
                motionSampleAgeMillis: motionAgeMillis,
                cumulativeStepCount: steps,
                stepAgeMillis: stepAgeMillis,
                stepCadenceHz: cadenceHz,
                persona: persona,
                powerMode: mode
            )
        }
    }

    struct Expectation: Decodable {
        let distanceMinMeters: Double
        let distanceMaxMeters: Double
        let finalState: String
        let routeSegmentsMin: Int
        let routeSegmentsMax: Int
        let sampleCount: Int
        let missingSpeedCount: Int
        let degradedSampleCount: Int
        let rejectedOutlierCount: Int
        let detectedStepCount: Int64
    }

    enum FixtureError: Error {
        case invalidValue(String)
    }

    static func required<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw FixtureError.invalidValue(message) }
        return value
    }

    static let syntheticBaseLatitude = 0.0
    static let syntheticBaseLongitude = 0.0
    static let metresPerDegree = 111_320.0
}

private extension Data {
    var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
