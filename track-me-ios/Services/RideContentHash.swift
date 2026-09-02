import CryptoKit
import Foundation

/// TASK-275: how a ride entered the database.
///
/// Stored as a `String` rather than an enum so an unknown future value degrades to "not recorded
/// here" instead of failing to decode, and so SwiftData needs no custom transformer.
enum RideSource {
    /// Produced by this app's recorder on this device. Earns levels and milestones.
    static let recorded = "RECORDED"

    /// Parsed from a GPX file. Viewable, exportable and syncable; earns no progress.
    static let imported = "IMPORTED"

    /// True only for the one value that may contribute to gamification.
    static func earnsProgress(_ source: String?) -> Bool { source == recorded }
}

/// TASK-275: identifies a ride by *what it is*, not by what a file claims about itself.
///
/// The import path deduped on a TrackMe id written into this app's own exports. That guard has two
/// holes, and only the second needs an adversary: a GPX from any other app carries no such id, so
/// the check was skipped entirely and importing the same export twice double-counted its minutes;
/// and deleting one XML attribute defeats it, because the track is unchanged either way.
///
/// ## Why this hashes timestamps rather than every coordinate
///
/// The first Android version hashed every point at five decimal places and failed on a device at
/// the very case it was written for: exporting a recorded ride and importing it back produced a
/// *different* hash, because 18 of 361 points sat within a float's breath of a rounding boundary
/// and tipped the other way. Any fixed rounding has that failure — a coarser grid makes the
/// boundary rarer, never absent, and one flipped point changes the whole digest.
///
/// Timestamps do not have that problem. They are integers, they survive every serialisation either
/// app performs, and a ride is far better identified by *when* each sample was taken than by where.
/// The coarse endpoints guard against two rides at identical instants in different places; at three
/// decimals (~110 m) they are orders of magnitude above round-trip noise.
///
/// The canonical form is byte-identical to Android's so the two platforms agree on identity, which
/// matters for a ride recorded on one and synced to the other.
///
/// **Known and accepted:** two riders on the same group ride produce near-identical timestamps and
/// endpoints, so importing a companion's GPX of a ride you also recorded may be reported as a
/// duplicate. Two files describing the same ride at the same instants are duplicates under any
/// reasonable definition, and the alternative — failing to dedupe at all — is the bug this fixes.
enum RideContentHash {

    /// ~110 m. Far above float round-trip noise, far below the gap between distinct rides.
    private static let endpointFormat = "%.3f"

    /// A stable hex digest of the track, or `nil` when there is nothing to identify.
    ///
    /// Under two points returns `nil`: one sample cannot distinguish two activities, and the caller
    /// falls back to its other checks rather than calling every one-point import a duplicate.
    static func of(_ points: [GPSPoint]) -> String? {
        guard points.count >= 2 else { return nil }
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        var canonical = "\(ordered.count)|"
        canonical += String(format: endpointFormat, first.latitude) + ","
        canonical += String(format: endpointFormat, first.longitude) + "|"
        canonical += String(format: endpointFormat, last.latitude) + ","
        canonical += String(format: endpointFormat, last.longitude) + "|"
        for point in ordered {
            canonical += "\(Int64(point.timestamp.timeIntervalSince1970 * 1000));"
        }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
