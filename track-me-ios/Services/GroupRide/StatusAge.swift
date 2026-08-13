import Foundation

nonisolated enum StatusAge {
    struct Anchor: Codable, Equatable {
        let ageAtReceiptMillis: Int64
        let receivedAtElapsedMillis: Int64
        let isKnown: Bool

        static func unknown(receivedAtElapsedMillis: Int64) -> Anchor {
            Anchor(ageAtReceiptMillis: 0, receivedAtElapsedMillis: receivedAtElapsedMillis, isKnown: false)
        }
    }

    enum Bucket: Codable, Equatable {
        case now
        case seconds(Int)
        case minutes(Int)
        case hours(Int)
        case unknown
    }

    static let bootEpochToleranceMillis: Int64 = 60_000

    static func elapsedMillis() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded())
    }

    static func bootEpochMillis(wallNowMillis: Int64, elapsedMillis: Int64) -> Int64 {
        wallNowMillis - elapsedMillis
    }

    static func bootEpochChanged(stored: Int64, current: Int64) -> Bool {
        absDiff(stored, current) > bootEpochToleranceMillis
    }

    static func anchorPosition(
        serverNowMillis: Int64,
        serverTimestampMillis: Int64,
        receivedAtElapsedMillis: Int64
    ) -> Anchor {
        Anchor(
            ageAtReceiptMillis: nonnegativeDifference(serverNowMillis, serverTimestampMillis),
            receivedAtElapsedMillis: receivedAtElapsedMillis,
            isKnown: true
        )
    }

    static func anchorStatus(
        serverNowMillis: Int64,
        serverTimestampMillis: Int64,
        statusAgeSeconds: Int64?,
        receivedAtElapsedMillis: Int64
    ) -> Anchor {
        guard let statusAgeSeconds else {
            return .unknown(receivedAtElapsedMillis: receivedAtElapsedMillis)
        }
        let transit = nonnegativeDifference(serverNowMillis, serverTimestampMillis)
        let seconds = max(0, min(statusAgeSeconds, Int64.max / 1_000))
        let statusAge = seconds * 1_000
        let combined = transit > Int64.max - statusAge ? Int64.max : transit + statusAge
        return Anchor(
            ageAtReceiptMillis: combined,
            receivedAtElapsedMillis: receivedAtElapsedMillis,
            isKnown: true
        )
    }

    static func currentAgeMillis(anchor: Anchor, nowElapsedMillis: Int64) -> Int64 {
        let elapsed = nonnegativeDifference(nowElapsedMillis, anchor.receivedAtElapsedMillis)
        return anchor.ageAtReceiptMillis > Int64.max - elapsed
            ? Int64.max
            : anchor.ageAtReceiptMillis + elapsed
    }

    static func bucket(anchor: Anchor, nowElapsedMillis: Int64, syncIntervalSec: Int) -> Bucket {
        guard anchor.isKnown else { return .unknown }
        return bucket(ageMillis: currentAgeMillis(anchor: anchor, nowElapsedMillis: nowElapsedMillis), syncIntervalSec: syncIntervalSec)
    }

    static func bucket(ageMillis: Int64, syncIntervalSec: Int) -> Bucket {
        let age = max(0, ageMillis)
        let intervalMillis = Int64(max(1, syncIntervalSec)) * 1_000
        switch age {
        case ..<intervalMillis: return .now
        case ..<60_000: return .seconds(Int(age / 1_000))
        case ..<3_600_000: return .minutes(Int(age / 60_000))
        default: return .hours(Int(min(age / 3_600_000, Int64(Int.max))))
        }
    }

    private static func nonnegativeDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= rhs else { return 0 }
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? Int64.max : difference
    }

    private static func absDiff(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? nonnegativeDifference(lhs, rhs) : nonnegativeDifference(rhs, lhs)
    }
}
