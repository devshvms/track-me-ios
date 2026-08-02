import Foundation

/// The two cross-platform telemetry values for abandoning a just-started ride.
/// Keep this contract free of ride identifiers or location data.
enum RideStartAbortMethod: String {
    case preCommit = "pre_commit"
    case postCommitUndo = "post_commit_undo"
}

/// Identity-safe state for the short pre-commit launch window.
struct RideStartLaunchState: Equatable {
    private(set) var pendingToken: UUID?

    var isPending: Bool { pendingToken != nil }

    mutating func begin(token: UUID = UUID()) {
        pendingToken = token
    }

    mutating func abort(observedToken: UUID) -> Bool {
        guard pendingToken == observedToken else { return false }
        pendingToken = nil
        return true
    }

    mutating func commit(observedToken: UUID) -> Bool {
        guard pendingToken == observedToken else { return false }
        pendingToken = nil
        return true
    }

    mutating func reset() {
        pendingToken = nil
    }
}

enum RideStartAbortPolicy {
    static let preCommitDelay: Duration = .milliseconds(420)
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
