import Foundation
import Combine

enum UnitSystem: String { case metric, imperial }
enum UnitPreference {
    static let key = "unit_system"
    static var current: UnitSystem { UnitSystem(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? deviceDefault }
    static var deviceDefault: UnitSystem {
        if #available(iOS 16, *) { return Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk ? .imperial : .metric }
        return Locale.current.usesMetricSystem ? .metric : .imperial
    }
}

/// Observable display preference shared by SwiftUI surfaces. Persisted values are always the
/// selected enum raw value; ride storage, GPX, and live-share payloads remain metric.
final class UnitSettings: ObservableObject {
    static let shared = UnitSettings()

    @Published private(set) var unit: UnitSystem

    private init() {
        unit = UnitPreference.current
    }

    func set(_ unit: UnitSystem) {
        guard self.unit != unit else { return }
        self.unit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: UnitPreference.key)
    }
}

enum UnitFormatter {
    static func distance(meters: Double, unit: UnitSystem, decimals: Int = 2) -> String {
        String(format: "%.*f %@", locale: Locale.current, decimals, unit == .imperial ? meters / 1609.344 : meters / 1000, distanceUnitLabel(unit))
    }

    static func distanceValue(meters: Double, unit: UnitSystem, decimals: Int = 2) -> String {
        String(format: "%.*f", locale: Locale.current, decimals, unit == .imperial ? meters / 1609.344 : meters / 1000)
    }

    static func distanceUnitLabel(_ unit: UnitSystem) -> String { unit == .imperial ? "mi" : "km" }

    static func speed(mps: Double, unit: UnitSystem) -> String {
        String(format: "%.1f %@", locale: Locale.current, mps * (unit == .imperial ? 2.236936 : 3.6), speedUnitLabel(unit))
    }

    static func speedUnitLabel(_ unit: UnitSystem) -> String { unit == .imperial ? "mph" : "km/h" }
}
