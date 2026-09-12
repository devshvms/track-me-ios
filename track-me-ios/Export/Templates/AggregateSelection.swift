import Foundation

/// SCOPE_1.8.9 Part 2 — what a *selection* of rides is, before anything is drawn.
///
/// ### Why this exists at all
///
/// Part 1 could assume its subject: one ride, one trace, one set of figures. A selection has no such
/// guarantee. Three rides that continue one another — Bengaluru → Hampi → Badami → Goa — are a
/// journey, and the thing worth showing is the sequence. Twelve Tuesday commutes are the same two
/// places twelve times, and rendering them as "A → B → C" would be nonsense. A year of weekend rides
/// around one city is neither.
///
/// So the template offered has to follow what the selection *is*, which is the same rule §9.3 used
/// when it found that three of the five single-ride templates cannot generalise: **forced by the
/// data, not by taste.**
///
/// Every decision here is made from coordinates and timestamps the device already holds. No
/// geocoding, no network, nothing that fails offline. The exact twin of Android's
/// `AggregateSelection`, down to the two thresholds — the shared vectors in
/// `AggregateSelectionVectorsTests` are what keep it that way.
nonisolated enum SelectionShape: String {
    /// Legs that continue one another. The sequence is the story.
    case tour
    /// Spread across a region with no chain. Coverage is the story.
    case territory
    /// Repeated or clustered. Accumulation is the only honest story.
    case collection
}

/// Whether a place was *stopped in* or merely reached — shvm's rule, 2026-09-11.
///
/// A region where one of the selected rides **starts** is `visited`: ending one recording there and
/// beginning another is evidence the rider was stationary, which is the thing "visited" should mean.
/// A region that only ever appears as a finish is `crossed` — reached, but with nothing to show the
/// rider stayed.
///
/// The honesty of the distinction is the point. It is derived entirely from the trimmed ends the app
/// already geocodes, so it never claims a region the data cannot support. Regions a leg passes
/// *through* without stopping are invisible to it, and deliberately not guessed at: closing that gap
/// needs offline boundary polygons, which is a separate decision.
nonisolated enum RegionRole: String { case visited, crossed }

/// Which administrative level a coverage count is about.
nonisolated enum AdminLevel {
    case district, state

    func of(_ parts: PlaceParts?) -> String? {
        let raw: String? = {
            switch self {
            case .district: return parts?.subAdministrativeArea
            case .state: return parts?.administrativeArea
            }
        }()
        let trimmed = raw?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// One selected ride, reduced to what an aggregate export needs.
nonisolated struct SelectionLeg: Equatable {
    var startLatitude: Double
    var startLongitude: Double
    var finishLatitude: Double
    var finishLongitude: Double
    var startPlace: PlaceParts? = nil
    var finishPlace: PlaceParts? = nil
    var distanceMeters: Double = 0
    var movingMillis: Int64 = 0
}

/// A named stop on a tour, with the district it sits in.
nonisolated struct ItineraryStop: Equatable {
    let name: String?
    let region: String?
}

/// The distance and moving time between two consecutive stops.
nonisolated struct ItineraryHop: Equatable {
    let distanceMeters: Double
    let movingMillis: Int64
}

/// A tour as the Itinerary template draws it: `stops.count == hops.count + 1`, always.
nonisolated struct Itinerary: Equatable {
    let stops: [ItineraryStop]
    let hops: [ItineraryHop]

    var totalMeters: Double { hops.reduce(0) { $0 + $1.distanceMeters } }
    var totalMillis: Int64 { hops.reduce(0) { $0 + $1.movingMillis } }
}

nonisolated enum AggregateSelection {

    /// How close a finish must be to the next start for the two to read as one journey.
    ///
    /// Generous on purpose. A rider who stops recording at a hotel and starts again at a petrol
    /// station the next morning has not broken the trip, and a tolerance tight enough to call that
    /// two separate journeys would almost never fire on real riding.
    static let chainJoinMeters: Double = 25_000

    /// How far apart the starts must be before a selection is coverage rather than repetition.
    ///
    /// Below this, the rides are the same neighbourhood seen many times — a commute, a local loop —
    /// and a map of them is one line drawn twelve times.
    static let territorySpreadMeters: Double = 50_000

    /// Which of the three shapes a selection is. Legs are expected oldest-first, the order every
    /// selection surface shows them in.
    static func shape(_ legs: [SelectionLeg]) -> SelectionShape {
        // One ride is not an aggregate, and an empty selection has nothing to be.
        guard legs.count >= 2 else { return .collection }

        // A tour is strict: *every* link must hold. One broken link and the set is not a single
        // journey, whatever the rest looks like — and drawing it as one would invent a leg the
        // rider never rode.
        let chained = zip(legs, legs.dropFirst()).allSatisfy { previous, next in
            metres(previous.finishLatitude, previous.finishLongitude, next.startLatitude, next.startLongitude) <= chainJoinMeters
        }
        // Chaining alone is not enough, and the case that proves it is the ordinary one: a commute
        // chains perfectly. You finish at the office, start again from the office, finish at home,
        // start again from home — every link holds, and it is not a journey, it is two places
        // twelve times.
        //
        // What separates them is whether the selection *goes* anywhere: a tour reaches roughly one
        // new place per leg. Net displacement cannot be the test, because a round trip ends where it
        // started and is still unmistakably a tour.
        if chained && distinctStops(legs) >= legs.count { return .tour }

        // Spread is measured across the starts rather than every point: it asks "does this person
        // set off from many places", which is what separates coverage from repetition. The widest
        // pair decides it.
        var widest: Double = 0
        for i in legs.indices {
            for j in legs.index(after: i)..<legs.endIndex {
                widest = max(widest, metres(legs[i].startLatitude, legs[i].startLongitude,
                                            legs[j].startLatitude, legs[j].startLongitude))
            }
        }
        return widest > territorySpreadMeters ? .territory : .collection
    }

    /// Regions the selection touched, each marked `.visited` or `.crossed`, in the order ridden.
    ///
    /// Visited wins wherever a region is both: a place you set off from at least once was somewhere
    /// you stayed, whatever else happened there.
    static func regions(_ legs: [SelectionLeg], level: AdminLevel) -> [(name: String, role: RegionRole)] {
        let visited = Set(legs.compactMap { level.of($0.startPlace) })
        var order: [String] = []
        var roles: [String: RegionRole] = [:]
        for leg in legs {
            if let start = level.of(leg.startPlace) {
                if roles[start] == nil { order.append(start) }
                roles[start] = .visited
            }
            // A region that is *anywhere* a start is left for that start to insert, even when the
            // start comes later in the selection. Inserting it here instead would put it earlier in
            // the order than Android does, and the order is what the Itinerary reads.
            if let finish = level.of(leg.finishPlace), !visited.contains(finish), roles[finish] == nil {
                order.append(finish)
                roles[finish] = .crossed
            }
        }
        // The invariant, stated where a reader will look for it: everything reached is either
        // visited or crossed, never dropped. Android says the same thing with a `check`.
        assert(Set(legs.compactMap { level.of($0.finishPlace) }).isSubset(of: Set(order)))
        return order.map { (name: $0, role: roles[$0]!) }
    }

    /// The stops and hops of a tour.
    ///
    /// Nil for anything that is not a `.tour` — an itinerary of a selection that is not a journey is
    /// a list of unrelated places pretending to be one.
    static func itinerary(_ legs: [SelectionLeg]) -> Itinerary? {
        guard shape(legs) == .tour, let first = legs.first else { return nil }
        let stops = [stop(first.startPlace)] + legs.map { stop($0.finishPlace) }
        let hops = legs.map { ItineraryHop(distanceMeters: $0.distanceMeters, movingMillis: $0.movingMillis) }
        return Itinerary(stops: stops, hops: hops)
    }

    private static func stop(_ parts: PlaceParts?) -> ItineraryStop {
        ItineraryStop(
            name: parts.flatMap(PlaceLabelPolicy.label),
            // The district sits under the name, which is where the administrative data earns its
            // place: "Vijayanagara" is how a reader who has never been there understands where
            // Hampi is.
            region: AdminLevel.district.of(parts)
        )
    }

    /// How many genuinely different places the selection stops at.
    ///
    /// Points within `chainJoinMeters` of one another are the same stop — the same tolerance that
    /// decides whether two legs connect, so "the same place" means one thing in this file.
    private static func distinctStops(_ legs: [SelectionLeg]) -> Int {
        guard let first = legs.first else { return 0 }
        let stops = [(first.startLatitude, first.startLongitude)] + legs.map { ($0.finishLatitude, $0.finishLongitude) }
        var clusters: [(Double, Double)] = []
        for stop in stops where !clusters.contains(where: { metres($0.0, $0.1, stop.0, stop.1) <= chainJoinMeters }) {
            clusters.append(stop)
        }
        return clusters.count
    }

    private static func metres(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        TemplateAnalytics.haversineMeters(lat1, lng1, lat2, lng2)
    }
}
