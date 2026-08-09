import Foundation

struct GroupBackoff {
    static let defaultSyncIntervalSec = 10
    static let maxRetryDelay: TimeInterval = 60

    var consecutiveFailures: Int = 0
    var random: () -> Double = { Double.random(in: 0.75...1.25) }

    mutating func reset() {
        consecutiveFailures = 0
    }

    mutating func nextDelay(retryAfter: TimeInterval? = nil) -> TimeInterval {
        consecutiveFailures += 1
        let base = retryAfter ?? min(Self.maxRetryDelay, pow(2, Double(min(consecutiveFailures, 6))))
        return min(Self.maxRetryDelay, base * random())
    }

    static func isRetryable(statusCode: Int, code: String?) -> Bool {
        if statusCode == 429 || statusCode == 503 { return true }
        if statusCode >= 500 { return true }
        return code == "REDIS_UNAVAILABLE"
    }
}
