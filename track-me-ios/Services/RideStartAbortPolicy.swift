import Foundation

/// The two cross-platform telemetry values for abandoning a just-started ride.
/// Keep this contract free of ride identifiers or location data.
enum RideStartAbortMethod: String {
    case preCommit = "pre_commit"
    case postCommitUndo = "post_commit_undo"
}

/// Identity-safe state for the pre-commit launch window or persona-choice bloom.
struct RideStartLaunchState: Equatable {
    private(set) var pendingToken: UUID?
    private(set) var awaitsPersonaChoice = false

    var isPending: Bool { pendingToken != nil }

    mutating func begin(token: UUID = UUID(), awaitsPersonaChoice: Bool = false) {
        pendingToken = token
        self.awaitsPersonaChoice = awaitsPersonaChoice
    }

    mutating func abort(observedToken: UUID) -> Bool {
        guard pendingToken == observedToken else { return false }
        pendingToken = nil
        awaitsPersonaChoice = false
        return true
    }

    mutating func commit(observedToken: UUID) -> Bool {
        guard pendingToken == observedToken else { return false }
        pendingToken = nil
        awaitsPersonaChoice = false
        return true
    }

    mutating func reset() {
        pendingToken = nil
        awaitsPersonaChoice = false
    }
}

enum RideStartAbortPolicy {
    static let preCommitDelay: Duration = .milliseconds(420)
    static let personaChoiceWindow: Duration = .milliseconds(2_500)
    static let postCommitWindowMillis: TimeInterval = 10_000
    static let postCommitDistanceMeters = 10.0

    static func canOfferPostCommitUndo(
        durationInMillis: TimeInterval,
        distanceMeters: Double
    ) -> Bool {
        durationInMillis < postCommitWindowMillis
            && distanceMeters < postCommitDistanceMeters
    }
}
