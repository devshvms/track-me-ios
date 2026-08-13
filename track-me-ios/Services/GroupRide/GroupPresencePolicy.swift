import Foundation

nonisolated enum GroupSyncFailureKind: String, Codable, Equatable {
    case noInternet
    case serviceUnavailable
    case auth
    case protocolFailure
}

nonisolated enum GroupPresencePolicy {
    enum Cause: Equatable {
        case local
        case relay
    }

    enum Pill: Equatable {
        case none
        case statusReminder(status: RiderStatus, age: StatusAge.Bucket)
        case statusUnsent(status: RiderStatus)
        case clearing(status: RiderStatus)
        case paused(cause: Cause, rideRecording: Bool, lastShared: StatusAge.Bucket)
        case pausedWithPendingStatus(
            cause: Cause,
            rideRecording: Bool,
            status: RiderStatus,
            isClearing: Bool
        )
        case notSharing(status: RiderStatus?, statusAcknowledged: Bool, isClearing: Bool)
    }

    struct Input: Equatable {
        let sessionActive: Bool
        let lastSuccessfulSyncElapsedMillis: Int64?
        let lastOwnPositionAckElapsedMillis: Int64?
        let lastFailureKind: GroupSyncFailureKind?
        let isSharingPosition: Bool
        let isRideRecording: Bool
        let selfStatus: RiderStatus?
        let selfStatusAge: StatusAge.Bucket
        let selfStatusAcknowledged: Bool
        let isClearingStatus: Bool
        let syncIntervalSec: Int
        let nowElapsedMillis: Int64
    }

    static let minimumPauseThresholdMillis: Int64 = 30_000

    static func pauseThresholdMillis(syncIntervalSec: Int) -> Int64 {
        max(minimumPauseThresholdMillis, Int64(max(1, syncIntervalSec)) * 2_000)
    }

    static func evaluate(_ input: Input) -> Pill {
        guard input.sessionActive else { return .none }

        if !input.isSharingPosition {
            return .notSharing(
                status: input.selfStatus,
                statusAcknowledged: input.selfStatusAcknowledged,
                isClearing: input.isClearingStatus
            )
        }

        let cause: Cause = input.lastFailureKind == .noInternet ? .local : .relay
        let paused = input.lastSuccessfulSyncElapsedMillis.map {
            input.nowElapsedMillis - $0 >= pauseThresholdMillis(syncIntervalSec: input.syncIntervalSec)
        } ?? false

        if paused {
            if let status = input.selfStatus,
               input.isClearingStatus || !input.selfStatusAcknowledged {
                return .pausedWithPendingStatus(
                    cause: cause,
                    rideRecording: input.isRideRecording,
                    status: status,
                    isClearing: input.isClearingStatus
                )
            }
            return .paused(
                cause: cause,
                rideRecording: input.isRideRecording,
                lastShared: lastSharedBucket(input)
            )
        }

        guard let status = input.selfStatus else { return .none }
        if input.isClearingStatus { return .clearing(status: status) }
        if !input.selfStatusAcknowledged { return .statusUnsent(status: status) }
        return .statusReminder(status: status, age: input.selfStatusAge)
    }

    private static func lastSharedBucket(_ input: Input) -> StatusAge.Bucket {
        guard let ack = input.lastOwnPositionAckElapsedMillis else { return .unknown }
        return StatusAge.bucket(
            ageMillis: max(0, input.nowElapsedMillis - ack),
            syncIntervalSec: input.syncIntervalSec
        )
    }
}
