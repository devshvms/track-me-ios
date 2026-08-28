import Combine
import SwiftUI

/// TASK-254: which group control Home asked Community to put the rider in front of.
///
/// Home now carries the entry point for group rides, but the controls that create and join stay
/// where they were built. Rather than duplicate them — two implementations of a consent-bearing
/// control is exactly how the two drift apart — Home records the intent here and switches tabs, and
/// Community consumes it.
///
/// **The platforms differ here, deliberately, because their Community screens do.** Android's
/// create and join are modal sheets, so its equivalent opens the requested sheet. iOS's are inline
/// Form sections, so there is no sheet to open; this focuses the matching field instead, which
/// makes SwiftUI scroll the Form to it. Same outcome — the rider lands on the control they asked
/// for — reached the way each platform is already built.
@MainActor
final class GroupEntryRequest: ObservableObject {
    static let shared = GroupEntryRequest()

    enum Action: Equatable { case create, join }

    @Published private(set) var pending: Action?

    private init() {}

    func request(_ action: Action) {
        pending = action
    }

    /// Cleared by whoever acted on it, so a stale request cannot re-fire on the next visit.
    func consume() {
        pending = nil
    }
}
