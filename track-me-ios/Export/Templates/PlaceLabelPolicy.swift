import Foundation

/// SCOPE_1.8.9 §7 — the export's place reference. Off by default: it is a new disclosure.
nonisolated enum PlaceReference: String, CaseIterable {
    case off, startAndFinish, finishOnly
}

/// The parts of a reverse-geocoded placemark the policy may look at. `thoroughfare` is only ever used
/// to **reject** a candidate — it is never rendered.
nonisolated struct PlaceParts: Equatable {
    var subLocality: String? = nil
    var locality: String? = nil
    var subAdministrativeArea: String? = nil
    var administrativeArea: String? = nil
    var thoroughfare: String? = nil
}

/// Neighbourhood or coarser, **never a street** (SCOPE_1.8.9 §7). The route's ends are trimmed 200 m
/// for privacy; a street name beside that route would be a finer disclosure than the geometry and
/// quietly undo the trim. The exact twin of Android's `PlaceLabelPolicy`.
nonisolated enum PlaceLabelPolicy {
    static let maxLength = 32

    static func label(_ parts: PlaceParts) -> String? {
        let street = parts.thoroughfare?.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = [parts.subLocality, parts.locality, parts.subAdministrativeArea, parts.administrativeArea]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            // Some geocoders put the street in the sub-locality slot. Equal to the street is a street.
            .filter { street == nil || street!.isEmpty || $0.lowercased() != street }
        guard let first = candidates.first else { return nil }
        guard first.count > maxLength else { return first }
        return String(first.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The one line a template prints, or nil. A loop names its place once.
    static func line(_ reference: PlaceReference, start: String?, finish: String?) -> String? {
        switch reference {
        case .off: return nil
        case .finishOnly: return finish
        case .startAndFinish:
            guard let start else { return finish }
            guard let finish else { return start }
            return start.caseInsensitiveCompare(finish) == .orderedSame ? start : "\(start) → \(finish)"
        }
    }
}
