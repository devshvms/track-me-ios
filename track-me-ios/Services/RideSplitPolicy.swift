import Foundation

enum RideSplitAction: Equatable { case none, warn, split }

enum RideSplitPolicy {
    static let warnThreshold  = 8_000
    static let splitThreshold = 9_000

    /// Decide from the *current segment* point count. `alreadyWarned` prevents
    /// re-warning every fix between 8,000 and 9,000.
    static func evaluate(pointCount: Int, alreadyWarned: Bool) -> RideSplitAction {
        if pointCount >= splitThreshold { return .split }
        if pointCount == warnThreshold && !alreadyWarned { return .warn }
        return .none
    }
}
