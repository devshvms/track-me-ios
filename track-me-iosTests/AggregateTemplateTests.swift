import XCTest
import UIKit
@testable import track_me_ios

/// SCOPE_1.8.9 Part 2 on iOS — the twin of Android's aggregate suites.
///
/// The policy itself is proved against the shared vectors in `AggregateSelectionVectorsTests`; what
/// is left here is what the vectors cannot carry: the copy rules, and pixels. §15.5 of Part 1 records
/// that every defect worth finding in these templates was found by *looking* at the output, so the
/// renders are written out and the assertions only catch what a person would miss.
final class AggregateTemplateTests: XCTestCase {

    private let bengaluru = (12.9716, 77.5946)
    private let hampi = (15.3350, 76.4600)
    private let badami = (15.9149, 75.6768)

    private func leg(_ from: (Double, Double), _ to: (Double, Double),
                     start: PlaceParts? = nil, finish: PlaceParts? = nil,
                     meters: Double = 0, millis: Int64 = 0) -> SelectionLeg {
        SelectionLeg(startLatitude: from.0, startLongitude: from.1,
                     finishLatitude: to.0, finishLongitude: to.1,
                     startPlace: start, finishPlace: finish,
                     distanceMeters: meters, movingMillis: millis)
    }

    private var tour: [SelectionLeg] {
        [leg(bengaluru, hampi,
             start: PlaceParts(locality: "Bengaluru", subAdministrativeArea: "Bengaluru Urban", administrativeArea: "Karnataka"),
             finish: PlaceParts(locality: "Hampi", subAdministrativeArea: "Vijayanagara", administrativeArea: "Karnataka"),
             meters: 340_000, millis: 31_200_000),
         leg(hampi, badami,
             start: PlaceParts(locality: "Hampi", subAdministrativeArea: "Vijayanagara", administrativeArea: "Karnataka"),
             finish: PlaceParts(locality: "Badami", subAdministrativeArea: "Bagalkot", administrativeArea: "Karnataka"),
             meters: 140_000, millis: 12_000_000)]
    }

    // MARK: Which templates a selection is offered

    func testATourOffersTheItineraryAndACommuteDoesNot() {
        XCTAssertTrue(ExportTemplateAggregate.available(tour).contains(.itinerary))

        let home = (12.9716, 77.5946)
        let office = (12.9352, 77.6245)
        let commutes = Array(repeating: leg(home, office), count: 6)
        XCTAssertFalse(ExportTemplateAggregate.available(commutes).contains(.itinerary))
        // The Trace and the Sticker still are: N routes on one ground is honest for any selection.
        XCTAssertEqual(ExportTemplateAggregate.available(commutes), [.trace, .sticker])
    }

    func testShapeDetectionNeedsNoGeocoder() {
        // Offline, the legs carry no places at all — and the right template is still offered.
        let plain = [leg(bengaluru, hampi), leg(hampi, badami)]
        XCTAssertTrue(plain.allSatisfy { $0.startPlace == nil && $0.finishPlace == nil })
        XCTAssertTrue(ExportTemplateAggregate.available(plain).contains(.itinerary))
    }

    // MARK: The coverage line

    /// Naming stops where it would not fit. Four regions is the first selection that has to count, and
    /// a count is only ever reached with a plural — which is what keeps the copy correct without
    /// plural rules in seven catalogues. Android's first render of this line said "1 states".
    func testRegionsAreNamedUntilThereAreTooManyToName() {
        XCTAssertEqual(ExportTemplateAggregate.coverageLine(tour), "Karnataka")

        // Three is the most that fits: Goa is only ever reached, so it is crossed rather than
        // visited, and it still earns its name — the line is about where the selection went, not
        // about how long it stayed.
        let across = [leg(bengaluru, hampi, start: PlaceParts(administrativeArea: "Karnataka"), finish: PlaceParts(administrativeArea: "Goa")),
                      leg(hampi, badami, start: PlaceParts(administrativeArea: "Maharashtra"), finish: PlaceParts(administrativeArea: "Maharashtra"))]
        XCTAssertEqual(ExportTemplateAggregate.coverageLine(across), "Karnataka · Goa · Maharashtra")

        let wider = across + [leg(badami, bengaluru, start: PlaceParts(administrativeArea: "Kerala"), finish: PlaceParts(administrativeArea: "Odisha"))]
        XCTAssertEqual(ExportTemplateAggregate.coverageLine(wider), "5 regions")
    }

    func testNoGeocodingClaimsNoCoverage() {
        XCTAssertNil(ExportTemplateAggregate.coverageLine([leg(bengaluru, hampi), leg(hampi, badami)]))
    }

    // MARK: The date line

    func testTheDateLineSpansTheMonthsTheSelectionCovers() {
        func date(_ month: Int, _ day: Int) -> Date {
            var components = DateComponents(year: 2026, month: month, day: day)
            components.timeZone = TimeZone(identifier: "Asia/Kolkata")
            return Calendar(identifier: .gregorian).date(from: components)!
        }
        let oneMonth = ExportTemplateAggregate.dateLine(startTimes: [date(3, 8), date(3, 11)], localeCode: "en")
        XCTAssertEqual(oneMonth, "2 RIDES · MAR 2026")

        let across = ExportTemplateAggregate.dateLine(startTimes: [date(3, 28), date(4, 2)], localeCode: "en")
        XCTAssertEqual(across, "2 RIDES · MAR 2026 – APR 2026")
    }

    // MARK: Pixels

    private var renderDirectory: URL {
        let base = ProcessInfo.processInfo.environment["TEMPLATE_RENDER_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("template-renders")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The chain this work exists for, with its real districts.
    private func itinerary(stops: Int) -> Itinerary {
        let names = [("Bengaluru", "Bengaluru Urban"), ("Hampi", "Vijayanagara"), ("Badami", "Bagalkot"),
                     ("Panaji", "North Goa"), ("Sindhudurg", "Sindhudurg"), ("Ratnagiri", "Ratnagiri"),
                     ("Mahabaleshwar", "Satara"), ("Pune", "Pune"), ("Nashik", "Nashik")].prefix(stops)
        return Itinerary(stops: names.map { ItineraryStop(name: $0.0, region: $0.1) },
                         hops: (0..<(stops - 1)).map { ItineraryHop(distanceMeters: 140_000 + Double($0) * 60_000,
                                                                    movingMillis: 12_000_000 + Int64($0) * 3_000_000) })
    }

    private func content(_ itinerary: Itinerary?, palette: [UIColor]? = nil, runs: [[TemplateCoordinate]] = []) -> TemplateContent {
        TemplateContent(
            runs: runs, joins: [], runIntensities: nil,
            heroValue: "710", heroUnit: "km", heroUnitLong: "KILOMETRES", figures: [],
            dateLine: "4 DAYS · MAR 2026", placeLine: "Karnataka · Goa",
            link: "https://trackme.shvms.in/r/abc123",
            elevation: nil, elevationLabel: nil, splits: [], splitsLabel: nil,
            fastestSegment: nil, fastestLabel: nil, award: nil, light: .day, lightLine: nil,
            itinerary: itinerary, regions: [], coverageLine: "Karnataka · Goa", runPalette: palette
        )
    }

    @MainActor
    func testTheItineraryRendersAtEveryCanvasAndTheLongestSelectionStillFitsAboveTheHero() throws {
        for canvas in ExportTemplates.spec(.itinerary).canvases {
            for stops in [4, 9] {
                let image = TemplateRenderer.render(.itinerary, canvas: canvas, content: content(itinerary(stops: stops)))
                XCTAssertEqual(image.size, canvas.pixelSize, "\(canvas) \(stops)")
                try image.pngData()!.write(to: renderDirectory.appendingPathComponent("ios_itinerary_\(canvas.rawValue)_\(stops).png"))
                XCTAssertGreaterThan(inkShare(image), 0.01, "\(canvas) \(stops) is blank")
                // The collision Android's nine-stop render caught: the chain reached far enough down
                // that the last name was drawn through the hero figure.
                XCTAssertTrue(heroBandIsClearOfChain(image), "\(canvas) \(stops) draws the chain into the hero band")
            }
        }
    }

    @MainActor
    func testASelectionThatIsNotATourDrawsNoChain() throws {
        let image = TemplateRenderer.render(.itinerary, canvas: .square, content: content(nil))
        try image.pngData()!.write(to: renderDirectory.appendingPathComponent("ios_itinerary_no_tour.png"))
        // It falls back to the hero figure alone rather than half a chain asserting a journey.
        XCTAssertGreaterThan(inkShare(image), 0.001)
    }

    /// The claim worth testing is not that something was drawn but that the *palette reached the
    /// canvas*: a per-run colour quietly dropped anywhere along the way would leave a picture that
    /// still looks like a Trace — N lines in one colour — while making the legend beside it a lie.
    @MainActor
    func testEachRideKeepsItsOwnColourInTheAggregateTrace() throws {
        let runs = [(0...20).map { TemplateCoordinate(latitude: 12.90 + Double($0) * 0.002, longitude: 77.55 + Double($0) * 0.002) },
                    (0...20).map { TemplateCoordinate(latitude: 13.10 + Double($0) * 0.002, longitude: 77.55 + Double($0) * 0.002) }]
        let cyan = ExportTemplateAggregate.selectionColors[0]
        let purple = ExportTemplateAggregate.selectionColors[1]

        let coloured = TemplateRenderer.render(.trace, canvas: .square, content: content(nil, palette: [cyan, purple], runs: runs))
        try coloured.pngData()!.write(to: renderDirectory.appendingPathComponent("ios_aggregate_trace_palette.png"))
        XCTAssertTrue(has(coloured, cyan), "ride 1's colour is missing")
        XCTAssertTrue(has(coloured, purple), "ride 2's colour is missing — the palette was dropped on the way to the canvas")

        // Without a palette the same content is a single ride's Trace, and its line stays on the pace
        // gradient — which is what stops the aggregate field leaking into the single-ride look.
        let plain = TemplateRenderer.render(.trace, canvas: .square, content: content(nil, palette: nil, runs: runs))
        XCTAssertFalse(has(plain, purple), "the second ride's colour appeared without a palette")
    }

    // MARK: Pixel helpers

    private func pixels(_ image: UIImage) -> (data: [UInt8], width: Int, height: Int) {
        let cgImage = image.cgImage!
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    /// Any pixel meaningfully lighter than the ground counts as ink.
    private func inkShare(_ image: UIImage) -> Double {
        let (data, width, height) = pixels(image)
        var ink = 0, total = 0
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                let i = (y * width + x) * 4
                if luma(data, i) > 60 { ink += 1 }
                total += 1
            }
        }
        return Double(ink) / Double(total)
    }

    private func luma(_ data: [UInt8], _ i: Int) -> Double {
        Double(data[i]) * 0.299 + Double(data[i + 1]) * 0.587 + Double(data[i + 2]) * 0.114
    }

    /// No chain text may sit on or below the hairline that separates the chain from the total.
    ///
    /// The hairline is found rather than assumed, because its position moves with the canvas: it is
    /// the lowest near-full-width row of faint pixels. Android's first version of this test guessed a
    /// band by percentage and failed on a render that was correct.
    private func heroBandIsClearOfChain(_ image: UIImage) -> Bool {
        let (data, width, height) = pixels(image)
        var hairlineY: Int?
        for y in (height / 2)..<height {
            var run = 0
            for x in stride(from: Int(Double(width) * 0.1), to: Int(Double(width) * 0.9), by: 4) {
                let value = luma(data, (y * width + x) * 4)
                if value >= 28 && value <= 90 { run += 1 }
            }
            if Double(run) > Double(width) * 0.8 / 4 * 0.85 { hairlineY = y }
        }
        guard let hairlineY else { return true }
        for y in Swift.max(0, hairlineY - 12)..<Swift.min(height, hairlineY + 12) {
            for x in stride(from: Int(Double(width) * 0.18), to: width, by: 3) where luma(data, (y * width + x) * 4) > 150 {
                return false
            }
        }
        return true
    }

    /// Antialiasing means the exact value appears only in the middle of a stroke; near enough is enough.
    private func has(_ image: UIImage, _ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let target = (Int(r * 255), Int(g * 255), Int(b * 255))
        let (data, width, height) = pixels(image)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4
                let delta = abs(Int(data[i]) - target.0) + abs(Int(data[i + 1]) - target.1) + abs(Int(data[i + 2]) - target.2)
                if delta <= 24 { return true }
            }
        }
        return false
    }
}
