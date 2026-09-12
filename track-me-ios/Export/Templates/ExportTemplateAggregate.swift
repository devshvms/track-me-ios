import CoreLocation
import UIKit

/// SCOPE_1.8.9 Part 2 — turning a *selection* of rides into something a template can draw.
///
/// The single-ride twin of this is `ExportTemplateBuilder`, and the division is the same: this is the
/// one place that decides what an aggregate template *says*, so the renderer never formats and never
/// resolves a string. The twin of Android's `ExportTemplateAggregate`.
enum ExportTemplateAggregate {

    /// The most rides one picture can carry. Android's `MAX_COMPARISON_RIDES`, and the number the
    /// Itinerary's layout is proved against at nine stops.
    static let maxRides = 8

    /// One colour per selected ride, in selection order.
    ///
    /// Identical values to Android's `comparisonRouteColors`, deliberately: the same trip shared from
    /// each phone should not disagree about which ride is blue.
    static let selectionColors: [UIColor] = [
        UIColor(rgb: 0x00A6C7), // TrackMe cyan
        UIColor(rgb: 0x7557B5),
        UIColor(rgb: 0x008577),
        UIColor(rgb: 0xD97706),
        UIColor(rgb: 0x2F6FED),
        UIColor(rgb: 0xC2417A),
        UIColor(rgb: 0x4B7F52),
        UIColor(rgb: 0x8A5A2B)
    ]

    /// Oldest first and capped, which is what `AggregateSelection` expects and what Android's
    /// `prepareComparisonRoutes` guarantees. History shows rides newest-first, so a selection taken
    /// straight from that list would be read as a journey running backwards.
    static func ordered(_ rides: [Ride]) -> [Ride] {
        Array(rides.sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }.prefix(maxRides))
    }

    /// The drawable points of one ride, trimmed exactly as every other export surface trims them.
    static func points(_ ride: Ride, privacyTrim: Bool = true) -> [GPSPoint] {
        ExportPreviewView.renderPoints(ExportTemplateBuilder.sortedPoints(ride), privacyTrim: privacyTrim)
    }

    /// The legs of a selection, without geocoding.
    ///
    /// Shape detection needs only coordinates, so it must not wait on the network — a rider offline
    /// still gets the right templates offered, they just carry no place names.
    static func legs(_ rides: [Ride]) -> [SelectionLeg] {
        ordered(rides).compactMap { ride in
            let snapshot = ride.aggregateSnapshot
            return leg(points(ride), distanceMeters: snapshot.distanceMeters, movingMillis: snapshot.movingDurationMillis)
        }
    }

    /// One ride's drawn ends, as a leg.
    ///
    /// The ends come from `ExportTemplateBuilder.drawnCoordinate`, which is the presentation
    /// coordinate rather than the raw recording (TASK-325): an itinerary describes the journey as it
    /// is *drawn*, so the ends that decide whether two rides chain have to be the ends the rider
    /// sees joined. They differ by metres, far below the 25 km chain tolerance — the point is that
    /// the chain and the line cannot start telling different stories later.
    ///
    /// Separate from `legs(_:)` so the gate can reach it without a persistent store behind it.
    static func leg(_ drawn: [GPSPoint], distanceMeters: Double, movingMillis: Int64) -> SelectionLeg? {
        guard let start = drawn.first, let finish = drawn.last else { return nil }
        let from = ExportTemplateBuilder.drawnCoordinate(start)
        let to = ExportTemplateBuilder.drawnCoordinate(finish)
        return SelectionLeg(
            startLatitude: from.latitude, startLongitude: from.longitude,
            finishLatitude: to.latitude, finishLongitude: to.longitude,
            distanceMeters: distanceMeters,
            movingMillis: movingMillis
        )
    }

    /// The same legs with their ends resolved to places.
    ///
    /// Two lookups per leg, on the trimmed ends only — the same granularity Part 1 ships, so an
    /// aggregate export can never disclose more finely than a single-ride one. One at a time, because
    /// Apple rate-limits reverse geocoding. A leg whose lookup came back empty simply contributes no
    /// place, and the itinerary renders with a gap rather than refusing.
    static func legsWithPlaces(_ rides: [Ride], geocode: (CLLocation) async -> PlaceParts?) async -> [SelectionLeg] {
        var resolved: [SelectionLeg] = []
        for leg in legs(rides) {
            var copy = leg
            copy.startPlace = await geocode(CLLocation(latitude: leg.startLatitude, longitude: leg.startLongitude))
            copy.finishPlace = await geocode(CLLocation(latitude: leg.finishLatitude, longitude: leg.finishLongitude))
            resolved.append(copy)
        }
        return resolved
    }

    /// Which aggregate templates this selection can honestly fill.
    ///
    /// The Itinerary appears only for a tour: it draws a sequence, and a selection that is not a
    /// journey has none to draw. Offering it anyway and rendering an empty frame would be the failure
    /// §9.3 spent its whole argument avoiding.
    static func available(_ legs: [SelectionLeg]) -> [ExportTemplateID] {
        let shape = AggregateSelection.shape(legs)
        return ExportTemplates.all
            .filter { $0.scope == .aggregate || $0.scope == .both }
            .map(\.id)
            .filter { $0 != .itinerary || shape == .tour }
    }

    /// Where the selection went: "Karnataka · Goa", or "5 regions" when there are too many to name.
    ///
    /// Naming beats counting, and not only because it reads better — a count has to choose a noun,
    /// and the first render of this line on Android said "1 states". Up to `namedRegions` the line
    /// names them in the order ridden and the grammar problem disappears with the noun; past that the
    /// count is always plural, so the fallback is safe in every catalogue.
    ///
    /// Districts are deliberately absent: the Itinerary already prints one under every stop.
    static let namedRegions = 3

    static func coverageLine(_ legs: [SelectionLeg]) -> String? {
        let regions = AggregateSelection.regions(legs, level: .state).map(\.name)
        guard !regions.isEmpty else { return nil }
        if regions.count <= namedRegions { return regions.joined(separator: " · ") }
        return LocalizationHelper.formatted("%d regions", regions.count)
    }

    /// "3 RIDES · MAR 2026", or a span when the selection crosses a month.
    ///
    /// Takes the start times rather than the rides: it reads nothing else from them, and a selection
    /// of dates is testable without a persistent store behind it.
    static func dateLine(startTimes: [Date], localeCode: String? = nil) -> String {
        let language = Locale(identifier: localeCode ?? LocalizationHelper.selectedLanguageCode)
        let rideCount = LocalizationHelper.formatted("%d rides", startTimes.count)
        let times = startTimes.sorted()
        guard let first = times.first, let last = times.last else { return rideCount.uppercased(with: language) }
        let formatter = DateFormatter()
        formatter.locale = language
        formatter.setLocalizedDateFormatFromTemplate("MMMy")
        let from = formatter.string(from: first)
        let to = formatter.string(from: last)
        let span = from == to ? from : "\(from) – \(to)"
        return "\(rideCount) · \(span)".uppercased(with: language)
    }

    /// The selection's geometry, in the order the strip shows it.
    ///
    /// Each ride goes through the same `RideGaps` seam a single-ride export uses, so a gap in a
    /// recording is a dotted join here exactly as it is there — and then the runs are concatenated
    /// rather than merged, which is what keeps "run 3 belongs to ride 2" true for the palette.
    private static func geometry(_ rides: [Ride], privacyTrim: Bool)
        -> (runs: [[TemplateCoordinate]], joins: [[TemplateCoordinate]], palette: [UIColor]) {
        var runs: [[TemplateCoordinate]] = []
        var joins: [[TemplateCoordinate]] = []
        var palette: [UIColor] = []
        let coordinate = ExportTemplateBuilder.drawnCoordinate
        for (index, ride) in ordered(rides).enumerated() {
            let drawn = points(ride, privacyTrim: privacyTrim)
            guard drawn.count >= 2 else { continue }
            let colour = selectionColors[index % selectionColors.count]
            let recorded = RideGaps.recordedRuns(drawn, persona: ride.ridePersona)
            for run in recorded where run.count >= 2 {
                runs.append(run.map(coordinate))
                palette.append(colour)
            }
            if recorded.count > 1 {
                for gap in 0..<(recorded.count - 1) {
                    if let end = recorded[gap].last, let start = recorded[gap + 1].first {
                        joins.append([coordinate(end), coordinate(start)])
                    }
                }
            }
        }
        return (runs, joins, palette)
    }

    static func build(
        rides: [Ride],
        legs: [SelectionLeg],
        privacyTrim: Bool,
        unit: UnitSystem,
        dateLine: String,
        localeCode: String? = nil
    ) -> TemplateContent {
        let language = Locale(identifier: localeCode ?? LocalizationHelper.selectedLanguageCode)
        let geometry = geometry(rides, privacyTrim: privacyTrim)
        let coverage = coverageLine(legs)
        let totalMeters = legs.reduce(0) { $0 + $1.distanceMeters }
        return TemplateContent(
            runs: geometry.runs,
            joins: geometry.joins,
            // Pace is a single ride's story. Across a selection the line says which ride it is, and
            // `runPalette` is the channel that says so.
            runIntensities: nil,
            // The same formatter the single-ride hero uses: an aggregate total must not read in a
            // different precision from the figures it is the sum of.
            heroValue: UnitFormatter.distanceValue(meters: totalMeters, unit: unit, decimals: 1),
            heroUnit: UnitFormatter.distanceUnitLabel(unit),
            heroUnitLong: LocalizationHelper.localized(unit == .imperial ? "Miles" : "Kilometres", localeCode: localeCode).uppercased(with: language),
            figures: [],
            dateLine: dateLine,
            // The aggregate Trace has one line of room above its hero, and what a selection has to
            // say there is where it went — the same sentence the Itinerary puts in its footer.
            placeLine: coverage,
            // No corner link: a selection is not one artifact, and `/r/<id>` for whichever ride came
            // first would attribute the whole picture to it.
            link: nil,
            elevation: nil,
            elevationLabel: nil,
            splits: [],
            splitsLabel: nil,
            fastestSegment: nil,
            fastestLabel: nil,
            award: nil,
            light: .day,
            lightLine: nil,
            itinerary: AggregateSelection.itinerary(legs),
            regions: AggregateSelection.regions(legs, level: .district),
            coverageLine: coverage,
            runPalette: geometry.palette
        )
    }
}
