import CoreLocation
import XCTest
@testable import track_me_ios

/// SCOPE_1.8.9 §11 gate 1, re-run on a **V2-recorded** ride — the obligation §15.8 item 3 left open,
/// and the twin of Android's `V2RouteShapeGateTest`.
///
/// Gate 1 was proved against synthetic `TemplateCoordinate` lists, which enter the projection already
/// decided. TASK-325 put a second coordinate on every point: the raw recording stays as evidence and
/// the V2 estimator's display geometry is what surfaces draw. So the gate has to be asked again one
/// layer down — *from stored points* — or it certifies a shape the app no longer draws.
///
/// The divergence used here is far larger than V2's real correction, which moves points by metres.
/// That is deliberate: the question is which field the drawing path reads, and a metre-scale
/// difference would pass whichever answer were true.
final class V2RouteShapeGateTests: XCTestCase {

    private let metersPerDegree = 111_320.0

    private func corners(_ widthMeters: Double, _ heightMeters: Double, latitude: Double) -> [(Double, Double)] {
        let dLat = heightMeters / metersPerDegree
        let dLng = widthMeters / (metersPerDegree * cos(latitude * .pi / 180))
        let south = latitude - dLat / 2
        let north = latitude + dLat / 2
        return [(south, 10), (south, 10 + dLng), (north, 10 + dLng), (north, 10), (south, 10)]
    }

    /// A closed rectangle on the ground: `raw` metres in the stored coordinate, `display` metres in
    /// the V2 one, so the two disagree about the ride's shape and only one of them can be drawn.
    private func points(rawWidth: Double, rawHeight: Double, displayWidth: Double, displayHeight: Double,
                        withDisplay: Bool = true, latitude: Double = 12.97) -> [GPSPoint] {
        let raw = corners(rawWidth, rawHeight, latitude: latitude)
        let display = corners(displayWidth, displayHeight, latitude: latitude)
        return raw.indices.map { index in
            GPSPoint(
                latitude: raw[index].0,
                longitude: raw[index].1,
                altitude: 900,
                accuracy: 5,
                speed: 5,
                timestamp: Date(timeIntervalSince1970: Double(index) * 10),
                displayLatitude: withDisplay ? display[index].0 : nil,
                displayLongitude: withDisplay ? display[index].1 : nil
            )
        }
    }

    private func aspect(_ stored: [GPSPoint], in box: CGRect) -> Double {
        let runs = RideGaps.recordedRuns(stored, persona: .cycling)
        let line = runs.flatMap { $0 }.map { TemplateCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        let projected = RouteProjection.fit(line, in: box)!.project(line)
        let width = projected.map(\.x).max()! - projected.map(\.x).min()!
        let height = projected.map(\.y).max()! - projected.map(\.y).min()!
        return Double(width / height)
    }

    func testAV2RideIsDrawnInTheDisplayRoutesShapeNotTheRawRecordings() {
        // Raw says two-by-one; V2 says square. A template that still read the stored coordinate
        // would come out twice as wide as the ride the rider is shown everywhere else.
        let stored = points(rawWidth: 2_000, rawHeight: 1_000, displayWidth: 1_000, displayHeight: 1_000)
        XCTAssertEqual(aspect(stored, in: CGRect(x: 0, y: 0, width: 1_080, height: 1_080)), 1, accuracy: 0.01)
    }

    func testTheDisplayShapeSurvivesEveryCanvasTheTemplatesDeclare() {
        let stored = points(rawWidth: 1_000, rawHeight: 1_000, displayWidth: 2_000, displayHeight: 1_000)
        for canvas in ExportTemplates.spec(.trace).canvases {
            let box = traceRouteBoxDesign(canvas)
            XCTAssertEqual(aspect(stored, in: box), 2, accuracy: 0.02, "aspect on \(canvas)")
            let line = RideGaps.recordedRuns(stored, persona: .cycling).flatMap { $0 }
                .map { TemplateCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            let projected = RouteProjection.fit(line, in: box)!.project(line)
            XCTAssertTrue(projected.allSatisfy { box.insetBy(dx: -0.5, dy: -0.5).contains($0) }, "the route left its box on \(canvas)")
        }
    }

    /// A legacy ride carries no display coordinate at all. It has to keep drawing exactly as it did
    /// before TASK-325 — the fallback is the whole reason the field is optional.
    func testAPreV2RideStillDrawsItsRawShape() {
        let stored = points(rawWidth: 2_000, rawHeight: 1_000, displayWidth: 1_000, displayHeight: 1_000, withDisplay: false)
        XCTAssertEqual(aspect(stored, in: CGRect(x: 0, y: 0, width: 1_080, height: 1_080)), 2, accuracy: 0.02)
    }

    /// SCOPE_1.8.9 §15.8 item 3, the Part 2 half: a selection chains on the ends the rider is
    /// *shown* joined.
    func testASelectionChainsOnTheDrawnEndsNotTheRawRecording() {
        func leg(rawStart: (Double, Double), rawFinish: (Double, Double),
                 displayStart: (Double, Double), displayFinish: (Double, Double)) -> [GPSPoint] {
            [GPSPoint(latitude: rawStart.0, longitude: rawStart.1, altitude: 0, accuracy: 5, speed: 5,
                      timestamp: Date(timeIntervalSince1970: 0),
                      displayLatitude: displayStart.0, displayLongitude: displayStart.1),
             GPSPoint(latitude: rawFinish.0, longitude: rawFinish.1, altitude: 0, accuracy: 5, speed: 5,
                      timestamp: Date(timeIntervalSince1970: 3_600),
                      displayLatitude: displayFinish.0, displayLongitude: displayFinish.1)]
        }
        let bengaluru = (12.9716, 77.5946), hampi = (15.3350, 76.4600), badami = (15.9149, 75.6768)
        let far = (12.0, 74.0)
        // Raw: leg 2 starts 300 km from where leg 1 finished — no chain. Display: it starts at Hampi.
        let first = leg(rawStart: bengaluru, rawFinish: hampi, displayStart: bengaluru, displayFinish: hampi)
        let second = leg(rawStart: far, rawFinish: badami, displayStart: hampi, displayFinish: badami)
        let legs = [first, second].map { stored -> SelectionLeg in
            SelectionLeg(
                startLatitude: stored.first!.coordinate.latitude, startLongitude: stored.first!.coordinate.longitude,
                finishLatitude: stored.last!.coordinate.latitude, finishLongitude: stored.last!.coordinate.longitude
            )
        }
        XCTAssertEqual(AggregateSelection.shape(legs), .tour, "the chain followed the raw ends")
    }
}
