import Foundation

enum GroupAgePresentation {
    static func text(_ bucket: StatusAge.Bucket, includesAgo: Bool = true) -> String? {
        let base: String
        switch bucket {
        case .now:
            return LocalizationHelper.localized("Now")
        case .seconds(let seconds):
            base = LocalizationHelper.formatted("%ds", seconds)
        case .minutes(let minutes):
            base = LocalizationHelper.formatted("%dm", minutes)
        case .hours(let hours):
            base = LocalizationHelper.formatted("%dh", hours)
        case .unknown:
            return nil
        }
        return includesAgo ? LocalizationHelper.formatted("%@ ago", base) : base
    }

    static func telemetryBucket(_ bucket: StatusAge.Bucket) -> GroupDirectionsAgeBucket {
        switch bucket {
        case .now: .now
        case .seconds: .seconds
        case .minutes: .minutes
        case .hours: .hours
        case .unknown: .unknown
        }
    }
}
