import XCTest
import UIKit
@testable import track_me_ios

/// SCOPE_1.8.9 Part 1 on iOS — the twin of Android's template suites. The route below is synthetic, a
/// parametric loop rather than anyone's ride, and renders are written only to a test directory.
final class ExportTemplateTests: XCTestCase {

    // MARK: Projection (§11 gate 1)

    private func rectangle(latitude: Double, widthMeters: Double, heightMeters: Double) -> [TemplateCoordinate] {
        let dLat = heightMeters / 111_320
        let dLng = widthMeters / (111_320 * cos(latitude * .pi / 180))
        let south = latitude - dLat / 2, north = latitude + dLat / 2
        return [TemplateCoordinate(latitude: south, longitude: 10), TemplateCoordinate(latitude: south, longitude: 10 + dLng),
                TemplateCoordinate(latitude: north, longitude: 10 + dLng), TemplateCoordinate(latitude: north, longitude: 10),
                TemplateCoordinate(latitude: south, longitude: 10)]
    }

    private func extent(_ points: [CGPoint]) -> CGSize {
        CGSize(width: points.map(\.x).max()! - points.map(\.x).min()!, height: points.map(\.y).max()! - points.map(\.y).min()!)
    }

    func testASquareOnTheGroundIsASquareOnTheCanvasAtEveryLatitude() {
        for latitude in [0.0, 12.97, 51.5, 60.0] {
            let route = rectangle(latitude: latitude, widthMeters: 1_000, heightMeters: 1_000)
            let size = extent(RouteProjection.fit(route, in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))!.project(route))
            XCTAssertEqual(Double(size.width / size.height), 1, accuracy: 0.01, "latitude \(latitude)")
        }
    }

    func testATwoByOneRouteStaysTwoByOneInATallFrame() {
        let route = rectangle(latitude: 60, widthMeters: 2_000, heightMeters: 1_000)
        let size = extent(RouteProjection.fit(route, in: CGRect(x: 0, y: 0, width: 900, height: 1_600))!.project(route))
        XCTAssertEqual(Double(size.width / size.height), 2, accuracy: 0.02)
        XCTAssertEqual(Double(size.width), 900, accuracy: 0.5)
    }

    func testNorthIsUpAndASinglePointIsCentred() {
        let projection = RouteProjection.fit([TemplateCoordinate(latitude: 12.90, longitude: 77.6), TemplateCoordinate(latitude: 12.95, longitude: 77.6)],
                                             in: CGRect(x: 0, y: 0, width: 400, height: 800))!
        XCTAssertLessThan(projection.project(TemplateCoordinate(latitude: 12.95, longitude: 77.6)).y,
                          projection.project(TemplateCoordinate(latitude: 12.90, longitude: 77.6)).y)
        let point = TemplateCoordinate(latitude: 12.9, longitude: 77.6)
        let single = RouteProjection.fit([point], in: CGRect(x: 0, y: 0, width: 300, height: 500))!.project(point)
        XCTAssertEqual(single.x, 150, accuracy: 0.01)
        XCTAssertEqual(single.y, 250, accuracy: 0.01)
        XCTAssertNil(RouteProjection.fit([], in: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    // MARK: Solar phase (§6.5) — NOAA, cross-checked against Meeus within 0.1°

    private func ist(_ month: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents(year: 2026, month: month, day: 21, hour: hour, minute: minute)
        components.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testABengaluruDayRunsDawnGoldenDayGoldenDuskNight() {
        let phases: [((Int, Int), LightPhase)] = [((4, 30), .night), ((5, 40), .dawn), ((6, 15), .goldenMorning), ((12, 0), .day),
                                                  ((18, 20), .goldenEvening), ((19, 0), .dusk), ((20, 30), .night)]
        for ((hour, minute), expected) in phases {
            XCTAssertEqual(SolarPhase.phase(latitude: 12.97, longitude: 77.59, at: ist(6, hour, minute)), expected, "\(hour):\(minute)")
        }
    }

    func testTheSameClockTimeIsDarkInWinterAndLightInSummer() {
        XCTAssertEqual(SolarPhase.phase(latitude: 28.61, longitude: 77.21, at: ist(12, 5, 50)), .night)
        XCTAssertEqual(SolarPhase.phase(latitude: 28.61, longitude: 77.21, at: ist(6, 5, 50)), .goldenMorning)
    }

    // MARK: Place policy (§7, §11 gate 3)

    func testThePlaceLabelIsNeighbourhoodOrCoarserAndNeverTheStreet() {
        XCTAssertEqual(PlaceLabelPolicy.label(PlaceParts(subLocality: "Koramangala", locality: "Bengaluru")), "Koramangala")
        XCTAssertEqual(PlaceLabelPolicy.label(PlaceParts(subLocality: "80 Feet Road", locality: "Bengaluru", thoroughfare: "80 feet road")), "Bengaluru")
        XCTAssertNil(PlaceLabelPolicy.label(PlaceParts(thoroughfare: "MG Road")))
        XCTAssertEqual(PlaceLabelPolicy.line(.startAndFinish, start: "Koramangala", finish: "Indiranagar"), "Koramangala → Indiranagar")
        XCTAssertEqual(PlaceLabelPolicy.line(.startAndFinish, start: "Koramangala", finish: "koramangala"), "Koramangala")
        XCTAssertNil(PlaceLabelPolicy.line(.off, start: "A", finish: "B"))
    }

    // MARK: The Award (§6.4, §11 gate 4)

    func testTheAwardCanSayNo() {
        func facts(_ reveal: EarnedReveal?, distance: Double = 41_700, active: Int64? = 8_000_000, source: String = RideSource.recorded) -> AwardFacts? {
            AwardEligibility.facts(reveal, source: source, storedDistanceMeters: distance, storedActiveMillis: active)
        }
        XCTAssertNil(facts(EarnedReveal(kind: .standard, previousBest: nil, milestoneCount: nil)))
        XCTAssertNil(facts(nil))
        XCTAssertNil(facts(EarnedReveal(kind: .firstRide, previousBest: nil, milestoneCount: nil), source: RideSource.imported))
        XCTAssertNil(facts(EarnedReveal(kind: .distancePR, previousBest: 38_200, milestoneCount: nil), distance: 38_000),
                     "a PR the stored ride no longer supports is not rendered")
        let pr = facts(EarnedReveal(kind: .distancePR, previousBest: 38_200, milestoneCount: nil))!
        XCTAssertEqual(pr.previousFraction, Float(38_200.0 / 41_700.0), accuracy: 1e-6)
        XCTAssertNil(facts(EarnedReveal(kind: .milestone, previousBest: nil, milestoneCount: nil)))
    }

    /// The reveal travels through Firestore, so both platforms must spell it the same way.
    func testRevealWireNamesAreAndroidsEnumNamesAndRoundTrip() {
        XCTAssertEqual([RevealKind.firstRide, .distancePR, .durationPR, .milestone, .standard].map(\.wireName),
                       ["FIRST_RIDE", "DISTANCE_PR", "DURATION_PR", "MILESTONE", "DEFAULT"])
        for kind in [RevealKind.firstRide, .distancePR, .durationPR, .milestone, .standard] {
            XCTAssertEqual(RevealKind(wireName: kind.wireName), kind)
        }
        XCTAssertNil(RevealKind(wireName: "GOLD_STAR"))
        XCTAssertEqual(AwardEligibility.parse(kind: "DISTANCE_PR", previousBest: 1, milestoneCount: nil)?.kind, .distancePR)
    }

    func testTheTransitionCarriesTheRecordsThisRideWasJudgedAgainst() {
        let calendar = WeekKey.mondayAnchored()
        func ride(_ id: String, _ meters: Double, _ minutes: Int64, _ day: Int) -> GoodRideSummary {
            var components = DateComponents(year: 2026, month: 9, day: day, hour: 8)
            components.timeZone = TimeZone(identifier: "Asia/Kolkata")
            let finished = Calendar(identifier: .gregorian).date(from: components)!
            return GoodRideSummary(rideId: id, finishedAtMillis: Int64(finished.timeIntervalSince1970 * 1_000),
                                   durationMillis: minutes * 60_000, distanceMeters: meters)
        }
        let before = RideStatsReducer.reduce(RideStats(), ride("a", 38_200, 90, 1), calendar).0
        let transition = RideStatsReducer.reduce(before, ride("b", 41_700, 80, 2), calendar).1
        XCTAssertTrue(transition.isDistancePR)
        XCTAssertEqual(transition.previousLongestDistanceMeters, 38_200)
        XCTAssertEqual(RevealSelector.previousBest(for: .distancePR, in: transition), 38_200)
        XCTAssertEqual(RevealSelector.previousBest(for: .durationPR, in: transition), 90 * 60_000)
        XCTAssertNil(RevealSelector.previousBest(for: .milestone, in: transition))
    }

    // MARK: Analytics (§6.3, §12 R4) — Android's cases, so the two agree

    private func point(_ index: Int, speed: Double = 3, altitude: Double = 0, seconds: TimeInterval? = nil, paused: Bool = false) -> TemplatePoint {
        TemplatePoint(latitude: 12.9 + Double(index) * 0.0001, longitude: 77.6, altitude: altitude, speed: speed,
                      timestamp: Date(timeIntervalSince1970: seconds ?? Double(index) * 10), isPaused: paused)
    }

    private let hundredMetreLegs: (TemplatePoint, TemplatePoint) -> Double = { _, _ in 100 }

    func testPaceIsFlatWhenTheRideHeldOnePaceAndRunsSlowToFastOtherwise() {
        XCTAssertTrue(TemplateAnalytics.paceIntensities((0..<50).map { point($0, speed: 4 + Double($0 % 2) * 0.1) })
            .allSatisfy { $0 == TemplateAnalytics.flatPaceIntensity })
        let build = TemplateAnalytics.paceIntensities((0..<60).map { point($0, speed: 2 + Double($0) * 0.1) })
        XCTAssertEqual(build.first!, 0, accuracy: 0.05)
        XCTAssertEqual(build.last!, 1, accuracy: 0.05)
    }

    func testTheElevationBandIsNilWithoutHonestDataAndFlatForAFlatRide() {
        XCTAssertNil(TemplateAnalytics.elevationProfile((0..<9).map { point($0, altitude: Double($0)) }, storedGainMeters: 5, distance: hundredMetreLegs))
        XCTAssertNil(TemplateAnalytics.elevationProfile((0..<40).map { point($0) }, storedGainMeters: 0, distance: hundredMetreLegs))
        XCTAssertNil(TemplateAnalytics.elevationProfile((0..<40).map { point($0, altitude: 900 + Double($0)) }, storedGainMeters: nil, distance: hundredMetreLegs))
        let flat = TemplateAnalytics.elevationProfile((0..<40).map { point($0, altitude: 910 + Double($0 % 3)) }, storedGainMeters: 2, distance: hundredMetreLegs)!
        XCTAssertTrue(flat.heights.allSatisfy { $0 < 0.2 })
    }

    /// Three kilometres of 100 m legs; the second is run in 20 s legs, the others in 36 s.
    private func threeKilometres() -> [TemplatePoint] {
        var time: TimeInterval = 0
        return (0...30).map { index in
            if index > 0 { time += (11...20).contains(index) ? 20 : 36 }
            return point(index, seconds: time)
        }
    }

    func testSplitsAndTheFastestSegmentMatchAndroid() {
        let points = threeKilometres()
        let splits = TemplateAnalytics.splits(points, imperial: false, distance: hundredMetreLegs)
        XCTAssertEqual(splits.map(\.isPartial), [false, false, false])
        XCTAssertEqual(TemplateAnalytics.fastest(splits)?.index, 2)
        let bars = TemplateAnalytics.splitBars(splits)
        XCTAssertEqual(bars.map(\.isFastest), [false, true, false])
        XCTAssertEqual(bars[1].heightFraction, 1, accuracy: 1e-4)
        let segment = TemplateAnalytics.fastestSplitSegment(points, imperial: false, drawn: points, distance: hundredMetreLegs)!
        XCTAssertGreaterThanOrEqual(segment.first!.latitude, points[9].latitude - 1e-9)
        XCTAssertLessThanOrEqual(segment.last!.latitude, points[20].latitude + 1e-9)
        XCTAssertNil(TemplateAnalytics.fastestSplitSegment(points, imperial: false, drawn: Array(points[21...30]), distance: hundredMetreLegs))
    }

    // MARK: Declarations (§5, §9.3)

    func testTheStripOrderScopeAndCanvasesAreTheContract() {
        // The contract is about the single-ride strip: those five must not reshuffle under a rider who
        // has learned where they are. Part 2's aggregate templates are appended after them and never
        // appear in that strip, so they cannot shift it — which is why the assertion is now "the
        // single-ride ids, in this order, first" rather than "these are all of them".
        XCTAssertEqual(ExportTemplates.all.filter { $0.scope != .aggregate }.map(\.id), [.trace, .instrument, .sticker, .hour, .award])
        XCTAssertEqual(ExportTemplates.all.filter { $0.scope == .aggregate }.map(\.id), [.itinerary],
                       "aggregate templates belong after the single-ride ones")
        XCTAssertEqual([ExportTemplateID.award, .instrument, .hour].map { ExportTemplates.spec($0).scope }, [.single, .single, .single])
        XCTAssertEqual(ExportTemplates.spec(.instrument).defaultCanvas, .portrait)
        XCTAssertEqual(ExportTemplates.canvas(for: .sticker, preferred: .story), .card)
        XCTAssertEqual(ExportTemplates.canvas(for: .trace, preferred: .square), .square)
        XCTAssertTrue(TemplateCanvas.allCases.allSatisfy { $0.pixelSize.width == 1080 })
        // The chips keep one order: the Instrument lists 4:5 first, and the row must not follow it.
        XCTAssertEqual(ExportTemplates.canvasChoices(for: .instrument), [.story, .portrait, .square])
        XCTAssertEqual(ExportTemplates.canvasChoices(for: .trace), ExportTemplates.canvasChoices(for: .instrument))
        XCTAssertEqual(ExportTemplates.canvasChoices(for: .sticker), [.card])
    }

    /// §12 R3 — the strip card's label is a fixed-width control (84 pt, caption2), so every catalog's
    /// names must leave 10 % of it spare at the default size and still fit one Dynamic Type step up.
    /// xLarge is 13/11 ≈ 1.18×, stricter than the 1.15 Android is held to.
    @MainActor
    func testEveryTemplateNameFitsItsStripCardInEveryCatalog() {
        let card: CGFloat = 84
        for code in ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"] {
            let english = ExportTemplates.all.map { ExportTemplateBuilder.templateName($0.id, localeCode: "en") }
            let names = ExportTemplates.all.map { ExportTemplateBuilder.templateName($0.id, localeCode: code) }
            if code != "en" { XCTAssertNotEqual(names, english, "\(code) resolves to its own catalog") }
            for name in names {
                for (category, spare) in [(UIContentSizeCategory.large, 0.10), (.extraLarge, 0.0)] {
                    let font = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                    let width = (name as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(width, card * (1 - spare), "\(code) \"\(name)\" at \(category.rawValue)")
                }
            }
        }
    }

    // MARK: Renderer — real pixels, written out for review

    private func content(award: AwardText? = nil, light: LightPhase = .dawn, place: String? = "Koramangala → Indiranagar") -> TemplateContent {
        let points: [TemplatePoint] = (0..<360).map { index in
            let t = (0.06 + Double(index) / 359 * 0.88) * 2 * .pi
            let quick = (120...239).contains(index)
            return TemplatePoint(latitude: 12.97 + 0.0125 * sin(t) + 0.0045 * sin(3 * t),
                                 longitude: 77.59 + 0.017 * cos(t) - 0.004 * cos(2 * t),
                                 altitude: 905 + 38 * sin(t - 0.6) + 12 * sin(3 * t),
                                 speed: quick ? 7.4 + Double(index % 7) * 0.12 : 4.6 + Double(index % 5) * 0.1,
                                 timestamp: Date(timeIntervalSince1970: Double(index) * 8), isPaused: false)
        }
        return TemplateContent(
            runs: [points.map(\.coordinate)], joins: [], runIntensities: [TemplateAnalytics.paceIntensities(points)],
            heroValue: "12.4", heroUnit: "km", heroUnitLong: "KILOMETRES",
            figures: [TemplateFigure(role: .duration, label: "DURATION", value: "48min"),
                      TemplateFigure(role: .elevation, label: "ELEVATION", value: "312 m"),
                      // The widest real case: a cycling speed under iOS's longer label.
                      TemplateFigure(role: .effort, label: "AVERAGE SPEED", value: "15.5 km/h")],
            dateLine: "SAT 6 SEP · 06:14 · CYCLING", placeLine: place, link: "https://trackme.shvms.in/r/abc123def456",
            elevation: TemplateAnalytics.elevationProfile(points, storedGainMeters: 312), elevationLabel: "ELEVATION · 312 M GAIN",
            splits: TemplateAnalytics.splitBars(TemplateAnalytics.splits(points, imperial: false)), splitsLabel: "SPLITS · MIN/KM",
            fastestSegment: TemplateAnalytics.fastestSplitSegment(points, imperial: false, drawn: points), fastestLabel: "FASTEST KM",
            award: award, light: light, lightLine: "FIRST LIGHT · 06:14")
    }

    private var renderDirectory: URL {
        let base = ProcessInfo.processInfo.environment["TEMPLATE_RENDER_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("template-renders")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @MainActor
    func testEveryTemplateRendersAtEveryCanvasAtTheDestinationsRealSize() throws {
        let award = AwardText(facts: AwardFacts(kind: .distancePR, previousBest: 38_200, milestoneCount: nil, previousFraction: Float(38_200.0 / 41_700.0)),
                              badge: "PR", badgeCaption: "DISTANCE", headline: "Longest yet", subline: "Previous best 38.2 km")
        for spec in ExportTemplates.all {
            for canvas in spec.canvases {
                let image = TemplateRenderer.render(spec.id, canvas: canvas, content: content(award: spec.id == .award ? award : nil))
                XCTAssertEqual(image.size, canvas.pixelSize, "\(spec.id) \(canvas)")
                XCTAssertEqual(image.scale, 1)
                try image.pngData()!.write(to: renderDirectory.appendingPathComponent("ios_\(spec.id.rawValue)_\(canvas.rawValue).png"))
            }
        }
        for phase in LightPhase.allCases {
            let image = TemplateRenderer.render(.hour, canvas: .story, content: content(light: phase))
            try image.pngData()!.write(to: renderDirectory.appendingPathComponent("ios_hour_story_\(phase.rawValue).png"))
        }
    }

    /// The basemap's veil and fade are lifted off Apple's mark whatever scale MapKit hands back. The
    /// first cut cropped the corner in `cgImage` pixels from a 3× snapshot: a magnified sliver of map
    /// with most of the mark cut away — caught only by looking, on the simulator.
    @MainActor
    func testTheBasemapKeepsApplesMarkUnveiledAtAnyImageScale() {
        let canvas = TemplateCanvas.portrait
        let width: CGFloat = 720
        let size = CGSize(width: width, height: (width / canvas.aspect).rounded(.down))
        let k = width / canvas.pixelSize.width
        // A grey map with a white mark where MapKit puts one: 14 pt in, 11–27 pt up, in frame points.
        let mark = CGRect(x: 14 * k, y: size.height - 27 * k, width: 49 * k, height: 16 * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let map = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(mark)
        }
        let radii = TemplateBackdrop.attributionFramePoints
        let backdrop = MapBackdrop(image: map, runs: [], joins: [], attributionSize: CGSize(width: radii.width * k, height: radii.height * k))
        let image = TemplateRenderer.render(.trace, canvas: canvas, content: content(place: nil), widthPx: width, backdrop: backdrop)

        func brightness(_ point: CGPoint) -> CGFloat {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -point.x, y: point.y - image.size.height + 1)
            context.draw(image.cgImage!, in: CGRect(origin: .zero, size: image.size))
            return CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
        }
        XCTAssertGreaterThan(brightness(CGPoint(x: mark.midX, y: mark.midY)), 0.9, "Apple's mark shows at full strength")
        XCTAssertLessThan(brightness(CGPoint(x: size.width * 0.85, y: size.height * 0.2)), 0.3, "the map elsewhere stays shaded")
    }

    @MainActor
    func testTheStickerIsTransparentOutsideItsPlate() {
        let image = TemplateRenderer.render(.sticker, canvas: .card, content: content())
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail("no pixels") }
        let bytesPerRow = cg.bytesPerRow, bytesPerPixel = cg.bitsPerPixel / 8
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let offset = y * bytesPerRow + x * bytesPerPixel
            switch cg.alphaInfo {
            case .premultipliedFirst, .first, .noneSkipFirst: return bytes[offset]
            default: return bytes[offset + 3]
            }
        }
        XCTAssertEqual(alpha(2, 2), 0, "the rounded corner is see-through")
        XCTAssertGreaterThan(alpha(cg.width / 2, cg.height / 2), 0, "the plate itself is there")
    }
}
