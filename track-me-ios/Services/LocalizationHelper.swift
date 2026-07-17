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
        let code = localeCode ?? Locale.current.language.languageCode?.identifier ?? "en"
        let prefix = code.prefix(2).lowercased()
        
        switch self {
        case .today:
            switch prefix {
            case "es": return "Hoy"
            case "fr": return "Aujourd'hui"
            case "de": return "Heute"
            case "hi": return "आज"
            case "ja": return "今日"
            case "zh": return "今天"
            default: return "Today"
            }
        case .yesterday:
            switch prefix {
            case "es": return "Ayer"
            case "fr": return "Hier"
            case "de": return "Gestern"
            case "hi": return "कल"
            case "ja": return "昨日"
            case "zh": return "昨天"
            default: return "Yesterday"
            }
        case .thisWeek:
            switch prefix {
            case "es": return "Esta semana"
            case "fr": return "Cette semaine"
            case "de": return "Diese Woche"
            case "hi": return "इस सप्ताह"
            case "ja": return "今週"
            case "zh": return "本周"
            default: return "This Week"
            }
        case .thisMonth:
            switch prefix {
            case "es": return "Este mes"
            case "fr": return "Ce mois-ci"
            case "de": return "Diesen Monat"
            case "hi": return "इस महीने"
            case "ja": return "今月"
            case "zh": return "本月"
            default: return "This Month"
            }
        case .older:
            switch prefix {
            case "es": return "Anteriores"
            case "fr": return "Plus ancien"
            case "de": return "Älter"
            case "hi": return "पुराने"
            case "ja": return "以前"
            case "zh": return "更早"
            default: return "Older"
            }
        }
    }
}

class LocalizationHelper {
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
        let code = Locale.current.language.languageCode?.identifier.prefix(2).lowercased() ?? "en"
        switch status {
        case "All":
            switch code {
            case "es": return "Todos"
            case "fr": return "Tous"
            case "de": return "Alle"
            case "hi": return "सभी"
            case "ja": return "すべて"
            case "zh": return "全部"
            default: return "All"
            }
        case "Synced":
            switch code {
            case "es": return "Sincronizados"
            case "fr": return "Synchronisé"
            case "de": return "Synchronisiert"
            case "hi": return "सिंक किया गया"
            case "ja": return "同期済み"
            case "zh": return "已同步"
            default: return "Synced"
            }
        case "Unsynced":
            switch code {
            case "es": return "No sincronizado"
            case "fr": return "Non synchronisé"
            case "de": return "Nicht synchronisiert"
            case "hi": return "असिंक"
            case "ja": return "未同期"
            case "zh": return "未同步"
            default: return "Unsynced"
            }
        default:
            return status
        }
    }
}
