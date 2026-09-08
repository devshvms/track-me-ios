import Foundation
import Combine

/// Platform-neutral result of an age-range request.
///
/// TASK-288. Apple's `DeclaredAgeRange` framework is iOS 26+, and its types previously appeared in
/// this file's method *signatures* — where the `#available` guard in the body could not help. That
/// is what pinned the whole app to a 26.2 deployment target. Keeping Apple's types out of the
/// domain layer is what lets TrackMe deploy to iOS 17, and it is the seam the "policy independent
/// of SwiftUI presentation" comment below always wanted.
enum AgeSignalResponse {
    /// The user shared a range. `lowerBound` is nil when they are below the lowest gate requested.
    case sharing(lowerBound: Int?)
    /// Declined, unavailable, unsupported region — or an OS older than the framework itself.
    case noSignal
}

enum AgeSignalCategory: String {
    case unknown
    case adult
    case minor
}

enum AgeSignalDecision: String {
    case allowed
    case blocked
}

@MainActor
final class AgeSignalManager: ObservableObject {
    static let shared = AgeSignalManager()

    private static let categoryKey = "ageSignalCategory"
    private static let decisionKey = "ageSignalDecision"
    private static let checkedAtKey = "ageSignalCheckedAt"

    private let defaults: UserDefaults
    @Published private(set) var decision: AgeSignalDecision?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.decision = AgeSignalDecision(rawValue: defaults.string(forKey: Self.decisionKey) ?? "")
    }

    var hasCheckedBefore: Bool {
        defaults.string(forKey: Self.decisionKey) != nil
    }

    /// Performs the one-shot check. The SwiftUI environment action is supplied by ContentView
    /// because Apple's API presents its consent UI from a view-backed context.
    func checkAndPersist(
        requestAgeRange: @escaping @Sendable (Int) async throws -> AgeSignalResponse
    ) async {
        guard !hasCheckedBefore else { return }

        let category = await requestCategory(requestAgeRange: requestAgeRange)
        let resolvedDecision: AgeSignalDecision = category == .minor ? .blocked : .allowed
        defaults.set(category.rawValue, forKey: Self.categoryKey)
        defaults.set(resolvedDecision.rawValue, forKey: Self.decisionKey)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: Self.checkedAtKey)
        decision = resolvedDecision
        TelemetryManager.shared.trackAgeSignalChecked(
            category: category.rawValue,
            decision: resolvedDecision.rawValue
        )
    }

    /// Pure mapping seam for unit tests and to keep policy independent of SwiftUI presentation.
    nonisolated static func category(forLowerBound lowerBound: Int?) -> AgeSignalCategory {
        guard let lowerBound else { return .minor }
        return lowerBound >= 18 ? .adult : .minor
    }

    private func requestCategory(
        requestAgeRange: @escaping @Sendable (Int) async throws -> AgeSignalResponse
    ) async -> AgeSignalCategory {
        // The availability check moved to the call site (`View.ageSignalCheck()`), which is the
        // only place that can name an iOS 26 type. Below iOS 26 the caller supplies `.noSignal`,
        // producing the identical `.unknown` -> `.allowed` outcome this guard used to produce.
        do {
            let response = try await requestAgeRange(18)
            guard case let .sharing(lowerBound) = response else {
                // Declined sharing (or a non-regulated region without a signal) fails open.
                return .unknown
            }
            return Self.category(forLowerBound: lowerBound)
        } catch {
            // Availability, region, and account errors must never block a legitimate user.
            return .unknown
        }
    }
}
