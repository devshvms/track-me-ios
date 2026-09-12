import XCTest
@testable import track_me_ios

/// SCOPE_1.8.9 Part 2 §9.3, proved against the frozen vectors.
///
/// `aggregate-selection-v1.json` is canonical in `track-me-web/tests/fixtures` and copied byte for
/// byte to both clients. The shape of a selection decides which aggregate templates a rider is
/// *offered*, so a platform that reads the same three rides as a tour where the other reads a
/// collection is not a rendering difference — it is a different feature on each phone.
///
/// Part 1 shipped with no vectors and the two sides agreed only because one was ported from the
/// other within a day. This file is what makes the next change to either side fail loudly.
///
/// Read from the repository rather than a test bundle so the file asserted against is the same file
/// a reviewer diffs — a copy bundled at build time can go stale without failing.
final class AggregateSelectionVectorsTests: XCTestCase {

    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/aggregate-selection-v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
            let alternative = directory
                .appendingPathComponent("track-me-iosTests/Resources/aggregate-selection-v1.json")
            if FileManager.default.fileExists(atPath: alternative.path) { found = alternative; break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "aggregate-selection-v1.json not found")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(vectors[key] as? [[String: Any]], "missing vector group: \(key)")
    }

    private func parts(_ raw: Any?) -> PlaceParts? {
        guard let entry = raw as? [String: Any] else { return nil }
        func value(_ key: String) -> String? { (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return PlaceParts(
            subLocality: value("sub_locality"),
            locality: value("locality"),
            subAdministrativeArea: value("sub_admin_area"),
            administrativeArea: value("admin_area"),
            thoroughfare: value("thoroughfare"),
            countryName: value("country")
        )
    }

    private func legs(_ raw: Any?) throws -> [SelectionLeg] {
        let array = try XCTUnwrap(raw as? [[String: Any]])
        return try array.map { entry in
            let start = try XCTUnwrap(entry["start"] as? [Double])
            let finish = try XCTUnwrap(entry["finish"] as? [Double])
            return SelectionLeg(
                startLatitude: start[0], startLongitude: start[1],
                finishLatitude: finish[0], finishLongitude: finish[1],
                startPlace: parts(entry["start_place"]),
                finishPlace: parts(entry["finish_place"]),
                distanceMeters: (entry["distance_meters"] as? Double) ?? 0,
                movingMillis: Int64((entry["moving_millis"] as? Int) ?? 0)
            )
        }
    }

    func testTheConstantsInTheVectorFileAreTheConstantsInTheCode() throws {
        let constants = try XCTUnwrap(vectors["constants"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(constants["chain_join_meters"] as? Double), AggregateSelection.chainJoinMeters)
        XCTAssertEqual(try XCTUnwrap(constants["territory_spread_meters"] as? Double), AggregateSelection.territorySpreadMeters)
    }

    func testEveryShapeVectorHolds() throws {
        for entry in try cases("shape") {
            let description = try XCTUnwrap(entry["description"] as? String)
            let expected = try XCTUnwrap(SelectionShape(rawValue: try XCTUnwrap(entry["expected"] as? String)))
            XCTAssertEqual(AggregateSelection.shape(try legs(entry["legs"])), expected, description)
        }
    }

    func testEveryRegionVectorHoldsInTheOrderRidden() throws {
        for entry in try cases("regions") {
            let description = try XCTUnwrap(entry["description"] as? String)
            let level: AdminLevel = try XCTUnwrap(entry["level"] as? String) == "state" ? .state : .district
            let actual = AggregateSelection.regions(try legs(entry["legs"]), level: level)
            let expected = try XCTUnwrap(entry["expected"] as? [[String: Any]])
            XCTAssertEqual(actual.count, expected.count, "\(description) — count")
            guard actual.count == expected.count else { continue }
            for (index, want) in expected.enumerated() {
                XCTAssertEqual(actual[index].name, want["name"] as? String, "\(description) — name at \(index)")
                XCTAssertEqual(actual[index].role.rawValue, want["role"] as? String, "\(description) — role at \(index)")
            }
        }
    }

    func testEveryItineraryVectorHolds() throws {
        for entry in try cases("itinerary") {
            let description = try XCTUnwrap(entry["description"] as? String)
            let actual = AggregateSelection.itinerary(try legs(entry["legs"]))
            guard let expected = entry["expected"] as? [String: Any] else {
                XCTAssertNil(actual, description)
                continue
            }
            let itinerary = try XCTUnwrap(actual, "\(description) — expected an itinerary")
            let stops = try XCTUnwrap(expected["stops"] as? [[String: Any]])
            XCTAssertEqual(itinerary.stops.count, stops.count, "\(description) — stop count")
            for (index, want) in stops.enumerated() where index < itinerary.stops.count {
                XCTAssertEqual(itinerary.stops[index].name, want["name"] as? String, "\(description) — name at \(index)")
                XCTAssertEqual(itinerary.stops[index].region, want["region"] as? String, "\(description) — region at \(index)")
            }
            let hops = try XCTUnwrap(expected["hops"] as? [[String: Any]])
            XCTAssertEqual(itinerary.hops.count, hops.count, "\(description) — hop count")
            for (index, want) in hops.enumerated() where index < itinerary.hops.count {
                XCTAssertEqual(itinerary.hops[index].distanceMeters, (want["distance_meters"] as? Double) ?? 0, accuracy: 0.001,
                               "\(description) — hop \(index) distance")
                XCTAssertEqual(itinerary.hops[index].movingMillis, Int64((want["moving_millis"] as? Int) ?? 0),
                               "\(description) — hop \(index) millis")
            }
            XCTAssertEqual(itinerary.totalMeters, try XCTUnwrap(expected["total_meters"] as? Double), accuracy: 0.001,
                           "\(description) — total metres")
            XCTAssertEqual(itinerary.totalMillis, Int64(try XCTUnwrap(expected["total_millis"] as? Int)),
                           "\(description) — total millis")
        }
    }
}
