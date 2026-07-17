import Foundation

enum DateBucket: Int, CaseIterable, Comparable {
    case today = 0
    case yesterday = 1
    case thisWeek = 2
    case thisMonth = 3
    case older = 4
    
    static func < (lhs: DateBucket, rhs: DateBucket) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    func localizedTitle(localeCode: String? = nil) -> String {
        switch self {
        case .today:
            return LocalizationHelper.localized("Today", localeCode: localeCode)
        case .yesterday:
            return LocalizationHelper.localized("Yesterday", localeCode: localeCode)
        case .thisWeek:
            return LocalizationHelper.localized("This Week", localeCode: localeCode)
        case .thisMonth:
            return LocalizationHelper.localized("This Month", localeCode: localeCode)
        case .older:
            return LocalizationHelper.localized("Older", localeCode: localeCode)
        }
    }
}

enum LocalizationHelper {
    /// The app stores the selected language in UserDefaults and applies the
    /// same locale to Foundation messages raised outside SwiftUI views.
    static var selectedLocale: Locale {
        let code = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        return Locale(identifier: code)
    }

    static func localized(_ value: String, localeCode: String? = nil) -> String {
        let locale = localeCode.map(Locale.init(identifier:)) ?? selectedLocale
        return String(localized: String.LocalizationValue(value), locale: locale)
    }

    static func bucket(for date: Date) -> DateBucket {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return .today
        } else if calendar.isDateInYesterday(date) {
            return .yesterday
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return .thisWeek
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .month) {
            return .thisMonth
        } else {
            return .older
        }
    }
    
    static func syncStatusTitle(_ status: String) -> String {
        switch status {
        case "All":
            return localized("All")
        case "Synced":
            return localized("Synced")
        case "Unsynced":
            return localized("Unsynced")
        default:
            return status
        }
    }
}
