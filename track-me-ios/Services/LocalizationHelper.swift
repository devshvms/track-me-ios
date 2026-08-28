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
        Locale(identifier: selectedLanguageCode)
    }

    static var selectedLanguageCode: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
    }

    /// TASK-241: the app rendered a mix of two languages whenever the in-app language differed from
    /// the device's.
    ///
    /// `String(localized:locale:)` looks like it selects a translation and does not. `locale:`
    /// governs *formatting within* the resolved string — numbers, dates, plural rules — while the
    /// **table** comes from `bundle:`, which defaults to `.main` and therefore resolves in the
    /// device language. So every one of this helper's ~469 call sites silently ignored the rider's
    /// choice, while plain SwiftUI `Text("…")` honoured it through `\.environment(\.locale)`. One
    /// screen showed both: "Statistiques du trajet" as a `Text`, "Distance" through this helper.
    ///
    /// The fix is to name the bundle. Everything routes through this one function, so the whole
    /// defect closes here rather than at the call sites — which is the only reason a ~469-site bug
    /// is a small change.
    static func localized(_ value: String, localeCode: String? = nil) -> String {
        let code = localeCode ?? selectedLanguageCode
        return String(
            localized: String.LocalizationValue(value),
            bundle: bundle(forLanguage: code),
            locale: Locale(identifier: code)
        )
    }

    /// TASK-241: a date in the rider's chosen language rather than the device's.
    ///
    /// `DateFormatter.localizedString` reads `Locale.current`, which is the device — the same trap
    /// as `String(localized:locale:)` one layer down, and it left a fully French screen printing an
    /// English date. Formatters are expensive to build, so the two shapes the app uses are cached
    /// per language and rebuilt only when the language changes.
    static func mediumDateTime(_ date: Date, includeTime: Bool) -> String {
        let code = selectedLanguageCode
        let formatter = dateFormatterLock.withLock { () -> DateFormatter in
            let key = "\(code)|\(includeTime)"
            if let cached = dateFormatters[key] { return cached }
            let made = DateFormatter()
            made.locale = Locale(identifier: code)
            made.dateStyle = .medium
            made.timeStyle = includeTime ? .short : .none
            dateFormatters[key] = made
            return made
        }
        return formatter.string(from: date)
    }

    private static let dateFormatterLock = NSLock()
    private nonisolated(unsafe) static var dateFormatters: [String: DateFormatter] = [:]

    static func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: selectedLocale, arguments: arguments)
    }

    /// Built once from what the app actually ships, so an added or removed translation needs no
    /// change here. Immutable after construction, which is what makes it safe to read from any
    /// thread — this is called from view bodies on every render, so it cannot take a lock.
    private static let bundlesByLanguage: [String: Bundle] = {
        var map: [String: Bundle] = [:]
        for code in Bundle.main.localizations {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                map[code] = bundle
            }
        }
        return map
    }()

    /// Resolves a language code to the bundle carrying its table.
    ///
    /// Exact match is the whole story today — the picker's codes are the `.lproj` names, Chinese
    /// included ("zh-Hans", not Android's "zh"). The looser steps exist so a future code that is
    /// merely *more specific* than a shipped translation ("pt-BR" against a "pt" table, "zh"
    /// against "zh-Hans") degrades to the right language instead of silently to English.
    ///
    /// Falling back to `.main` reproduces the old behaviour rather than crashing or blanking: an
    /// unknown language then reads in the device language, which is wrong but legible.
    static func bundle(forLanguage code: String) -> Bundle {
        if let exact = bundlesByLanguage[code] { return exact }

        let base = code.split(separator: "-").first.map(String.init) ?? code
        if let baseMatch = bundlesByLanguage[base] { return baseMatch }

        // Sorted so a language shipping two scripts resolves deterministically rather than by
        // whichever key the dictionary happened to yield first.
        let prefixed = bundlesByLanguage.keys
            .filter { $0.hasPrefix(base + "-") }
            .sorted()
        if let first = prefixed.first, let bundle = bundlesByLanguage[first] { return bundle }

        return .main
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
