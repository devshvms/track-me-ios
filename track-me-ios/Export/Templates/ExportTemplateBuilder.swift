import CoreLocation
import MapKit
import UIKit

/// The Templates tab's own choices (SCOPE_1.8.9 §9.2). Ratio and the privacy trim are global — they
/// describe the artifact, not the look — and live on the preview itself.
struct ExportTemplateChoice: Equatable {
    var id: ExportTemplateID = .trace
    var place: PlaceReference = .off
    /// Nil is the light the ride actually happened in.
    var lightOverride: LightPhase? = nil
    var mapBackground = false
}

/// Turns a ride into `TemplateContent` — the one place that decides what a template *says* — with the
/// iOS export's own formatters: `shareDuration` over moving time, `UnitFormatter` distance precision,
/// the detail screen's pace-or-speed rule (`EXPORT_SHARE_CONTRACTS.md` §1–2). The twin of Android's
/// `ExportTemplateContent`.
enum ExportTemplateBuilder {

    static func sortedPoints(_ ride: Ride) -> [GPSPoint] {
        (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    static func values(_ points: [GPSPoint]) -> [TemplatePoint] {
        points.map {
            TemplatePoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude,
                          speed: $0.speed, timestamp: $0.timestamp, isPaused: $0.isPaused)
        }
    }

    /// The templates this ride can honestly fill, in strip order — single-ride surfaces only (§9.3).
    static func available(for ride: Ride, unit: UnitSystem) -> [ExportTemplateID] {
        let all = values(sortedPoints(ride))
        let hasAward = awardFacts(for: ride) != nil
        let hasInstrument = TemplateAnalytics.splits(all, imperial: unit == .imperial).filter { !$0.isPartial }.count >= 2
            || TemplateAnalytics.elevationProfile(all, storedGainMeters: ride.aggregateSnapshot.elevationGainMeters) != nil
        return ExportTemplates.all.filter { $0.scope != .aggregate }.map(\.id).filter { id in
            switch id {
            case .award: return hasAward
            case .instrument: return hasInstrument
            default: return true
            }
        }
    }

    /// What the ride earned and still honestly supports; nil for everything else (§6.4).
    static func awardFacts(for ride: Ride) -> AwardFacts? {
        let aggregate = ride.aggregateSnapshot
        return AwardEligibility.facts(
            AwardEligibility.parse(kind: ride.revealKind, previousBest: ride.revealPreviousBest, milestoneCount: ride.revealMilestoneCount),
            source: ride.source,
            storedDistanceMeters: aggregate.distanceMeters,
            storedActiveMillis: aggregate.movingDurationMillis
        )
    }

    static func build(ride: Ride, choice: ExportTemplateChoice, privacyTrim: Bool, unit: UnitSystem) -> TemplateContent {
        let raw = sortedPoints(ride)
        // The same seam the still image and the video use, so the three can never disagree on the trim.
        let drawnRaw = ExportPreviewView.renderPoints(raw, privacyTrim: privacyTrim)
        let persona = ride.ridePersona
        let runs = RideGaps.recordedRuns(drawnRaw, persona: persona)
        func coordinate(_ point: GPSPoint) -> TemplateCoordinate { TemplateCoordinate(latitude: point.latitude, longitude: point.longitude) }
        var joins: [[TemplateCoordinate]] = []
        if runs.count > 1 {
            for index in 0..<(runs.count - 1) {
                if let end = runs[index].last, let start = runs[index + 1].first { joins.append([coordinate(end), coordinate(start)]) }
            }
        }
        let all = values(raw)
        let drawn = values(drawnRaw)
        let aggregate = ride.aggregateSnapshot
        let imperial = unit == .imperial
        let language = Locale(identifier: LocalizationHelper.selectedLanguageCode)
        func L(_ key: String) -> String { LocalizationHelper.localized(key) }
        func upper(_ value: String) -> String { value.uppercased(with: language) }

        let elevationText = aggregate.elevationGainMeters.map { UnitFormatter.elevation(meters: $0, unit: unit) }
        // The detail screen's own rule: walk and run read in pace, everything else in speed.
        let usesPace = persona == .walk || persona == .run
        var figures = [TemplateFigure(role: .duration, label: upper(L("Duration")),
                                      value: UnitFormatter.shareDuration(seconds: Double(aggregate.movingDurationMillis) / 1_000))]
        if let elevationText { figures.append(TemplateFigure(role: .elevation, label: upper(L("Elevation")), value: elevationText)) }
        if aggregate.avgSpeedMps > 0 {
            figures.append(usesPace
                ? TemplateFigure(role: .effort, label: upper(L("Average Pace")), value: UnitFormatter.pace(mps: aggregate.avgSpeedMps, unit: unit))
                : TemplateFigure(role: .effort, label: upper(L("Average Speed")), value: UnitFormatter.speed(mps: aggregate.avgSpeedMps, unit: unit)))
        }

        let time = timeText(ride.startTime, language: language)
        // Coarse position for the light only — read, never drawn, and never leaves the device.
        let light = choice.lightOverride
            ?? raw.first.map { SolarPhase.phase(latitude: $0.latitude, longitude: $0.longitude, at: ride.startTime) }
            ?? .day
        let paceUnit = "min" + UnitFormatter.paceUnitLabel(unit)

        return TemplateContent(
            runs: runs.map { $0.map(coordinate) },
            joins: joins,
            runIntensities: runs.map { TemplateAnalytics.paceIntensities(values($0)) },
            heroValue: UnitFormatter.distanceValue(meters: aggregate.distanceMeters, unit: unit, decimals: 1),
            heroUnit: UnitFormatter.distanceUnitLabel(unit),
            heroUnitLong: upper(L(imperial ? "Miles" : "Kilometres")),
            figures: figures,
            dateLine: upper([dateText(ride.startTime, language: language), time, L(persona.displayName)].joined(separator: " · ")),
            placeLine: PlaceLabelPolicy.line(choice.place, start: ride.placeLabelStart, finish: ride.placeLabelEnd),
            link: ReplayDeepLink.forRide(ride),
            elevation: TemplateAnalytics.elevationProfile(all, storedGainMeters: aggregate.elevationGainMeters),
            elevationLabel: elevationText.map { upper(String(format: L("Elevation · %@ gain"), $0)) },
            splits: TemplateAnalytics.splitBars(TemplateAnalytics.splits(all, imperial: imperial)),
            splitsLabel: upper(String(format: L("Splits · %@"), paceUnit)),
            fastestSegment: TemplateAnalytics.fastestSplitSegment(all, imperial: imperial, drawn: drawn),
            fastestLabel: upper(L(imperial ? "Fastest mile" : "Fastest km")),
            award: awardFacts(for: ride).flatMap { awardText($0, unit: unit, language: language) },
            light: light,
            lightLine: upper(lightLabel(light)) + " · " + time
        )
    }

    static func lightLabel(_ phase: LightPhase) -> String {
        switch phase {
        case .dawn: return LocalizationHelper.localized("First light")
        case .goldenMorning, .goldenEvening: return LocalizationHelper.localized("Golden hour")
        case .day: return LocalizationHelper.localized("Daylight")
        case .dusk: return LocalizationHelper.localized("Last light")
        case .night: return LocalizationHelper.localized("After dark")
        }
    }

    /// `localeCode` is for the strip's fit test, which measures every catalog; the app passes none.
    static func templateName(_ id: ExportTemplateID, localeCode: String? = nil) -> String {
        switch id {
        case .trace: return LocalizationHelper.localized("Trace", localeCode: localeCode)
        case .instrument: return LocalizationHelper.localized("Instrument", localeCode: localeCode)
        case .sticker: return LocalizationHelper.localized("Sticker", localeCode: localeCode)
        case .hour: return LocalizationHelper.localized("Hour", localeCode: localeCode)
        case .award: return LocalizationHelper.localized("Award", localeCode: localeCode)
        }
    }

    private static func awardText(_ facts: AwardFacts, unit: UnitSystem, language: Locale) -> AwardText? {
        func L(_ key: String) -> String { LocalizationHelper.localized(key) }
        switch facts.kind {
        case .distancePR:
            return AwardText(facts: facts, badge: L("PR"), badgeCaption: L("Distance").uppercased(with: language), headline: L("Longest yet"),
                             subline: facts.previousBest.map { String(format: L("Previous best %@"), UnitFormatter.distance(meters: $0, unit: unit, decimals: 1)) })
        case .durationPR:
            return AwardText(facts: facts, badge: L("PR"), badgeCaption: L("Duration").uppercased(with: language), headline: L("Longest time out"),
                             subline: facts.previousBest.map { String(format: L("Previous best %@"), UnitFormatter.shareDuration(seconds: $0 / 1_000)) })
        case .firstRide:
            return AwardText(facts: facts, badge: L("1st"), badgeCaption: L("Ride").uppercased(with: language), headline: L("First ride"), subline: nil)
        case .milestone:
            guard let count = facts.milestoneCount else { return nil }
            return AwardText(facts: facts, badge: "\(count)", badgeCaption: L("Rides").uppercased(with: language),
                             headline: String(format: L("%d rides"), count), subline: nil)
        case .standard:
            return nil
        }
    }

    private static func dateText(_ date: Date, language: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = language
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }

    private static func timeText(_ date: Date, language: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = language
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// SCOPE_1.8.9 §7 — place names for the route's ends, resolved **once**, only after the user turned the
/// place reference on, and only for the trimmed ends: the lookup never involves the true start or
/// finish, and `PlaceLabelPolicy` keeps the answer to neighbourhood-or-coarser.
enum PlaceLabelResolver {
    static func resolve(_ points: [GPSPoint], geocode: (CLLocation) async -> PlaceParts?) async -> (start: String?, end: String?) {
        let trimmed = RoutePrivacyTrim.trim(points.sorted { $0.timestamp < $1.timestamp }, trimMeters: 200)
        guard let first = trimmed.first, let last = trimmed.last else { return (nil, nil) }
        // One request at a time: Apple rate-limits reverse geocoding, and two is all this ever asks.
        let start = await geocode(CLLocation(latitude: first.latitude, longitude: first.longitude)).flatMap(PlaceLabelPolicy.label)
        let end = await geocode(CLLocation(latitude: last.latitude, longitude: last.longitude)).flatMap(PlaceLabelPolicy.label)
        return (start, end)
    }

    /// Apple's geocoder, mapped into the fields `PlaceLabelPolicy` may read. Nil when offline.
    static func appleGeocoder(_ location: CLLocation) async -> PlaceParts? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: LocalizationHelper.selectedLanguageCode))
        guard let placemark = placemarks?.first else { return nil }
        return PlaceParts(subLocality: placemark.subLocality, locality: placemark.locality,
                          subAdministrativeArea: placemark.subAdministrativeArea,
                          administrativeArea: placemark.administrativeArea, thoroughfare: placemark.thoroughfare)
    }
}

/// The Trace's lite basemap (SCOPE_1.8.9 §8): a snapshot with **no route on it** — the renderer draws the
/// line, so no untrimmed pixel can be baked in — framed so the route lands in the Trace's route box,
/// with every position then read back from `Snapshot.point(for:)`. The frame is ours; the projection is
/// MapKit's (`EXPORT_SHARE_CONTRACTS.md` "Never re-derive the map projection").
enum TemplateBackdrop {
    static func capture(content: TemplateContent, canvas: TemplateCanvas, widthPx: CGFloat) async -> MapBackdrop? {
        let size = CGSize(width: widthPx.rounded(), height: (widthPx / canvas.aspect).rounded(.down))
        let all = (content.runs + content.joins).flatMap { $0 }
        guard all.count >= 2 else { return nil }
        let mapPoints = all.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let minX = mapPoints.map(\.x).min()!, maxX = mapPoints.map(\.x).max()!
        let minY = mapPoints.map(\.y).min()!, maxY = mapPoints.map(\.y).max()!
        let unit = size.width / TemplateRenderer.designWidth
        let design = traceRouteBoxDesign(canvas)
        let box = CGRect(x: design.minX * unit, y: design.minY * unit, width: design.width * unit, height: design.height * unit)
        // Pixels per MapKit map point, from the tighter axis; then the frame that puts the route's
        // centre at the box's centre.
        let pixelsPerPoint = Swift.min(Double(box.width) / Swift.max(maxX - minX, 1), Double(box.height) / Swift.max(maxY - minY, 1))
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(
            x: (minX + maxX) / 2 - Double(box.midX) / pixelsPerPoint,
            y: (minY + maxY) / 2 - Double(box.midY) / pixelsPerPoint,
            width: Double(size.width) / pixelsPerPoint,
            height: Double(size.height) / pixelsPerPoint
        )
        options.size = size
        options.scale = 1
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        func place(_ line: [TemplateCoordinate]) -> [CGPoint] {
            line.map { snapshot.point(for: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
        return MapBackdrop(image: snapshot.image, runs: content.runs.map(place), joins: content.joins.map(place),
                           attributionSize: CGSize(width: size.width * 0.3, height: size.height * 0.05))
    }
}

/// SCOPE_1.8.9 §12 R8: the last template chosen is remembered globally — a chosen look is wanted again.
enum TemplateMemory {
    private static let key = "export_last_template"

    static func recall(available: [ExportTemplateID]) -> ExportTemplateID {
        let stored = UserDefaults.standard.string(forKey: key).flatMap(ExportTemplateID.init(rawValue:))
        if let stored, available.contains(stored) { return stored }
        return available.first ?? .trace
    }

    static func remember(_ id: ExportTemplateID) {
        UserDefaults.standard.set(id.rawValue, forKey: key)
    }
}
