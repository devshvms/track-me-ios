import Foundation

enum UnitSystem: String { case metric, imperial }
enum UnitPreference {
    static let key = "unit_system"
    static var current: UnitSystem { UnitSystem(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? deviceDefault }
    static var deviceDefault: UnitSystem {
        if #available(iOS 16, *) { return Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk ? .imperial : .metric }
        return Locale.current.usesMetricSystem ? .metric : .imperial
    }
}
enum UnitFormatter {
    static func distance(meters: Double, unit: UnitSystem, decimals: Int = 2) -> String { String(format: "%.*f %@", decimals, unit == .imperial ? meters / 1609.344 : meters / 1000, unit == .imperial ? "mi" : "km") }
    static func speed(mps: Double, unit: UnitSystem) -> String { String(format: "%.1f %@", mps * (unit == .imperial ? 2.236936 : 3.6), unit == .imperial ? "mph" : "km/h") }
}
