import Foundation
import Combine

enum UnitSystem: String { case metric, imperial }
enum UnitPreference {
    static let key = "unit_system"
    static var current: UnitSystem { UnitSystem(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? deviceDefault }
    static var deviceDefault: UnitSystem {
        Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk ? .imperial : .metric
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

    static func paceValue(mps: Double, unit: UnitSystem) -> String {
        guard mps >= 0.2 else { return "--" }
        let metersPerUnit = unit == .imperial ? 1609.344 : 1000.0
        let totalSeconds = min(Int((metersPerUnit / mps).rounded()), 99 * 60 + 59)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    static func paceUnitLabel(_ unit: UnitSystem) -> String { unit == .imperial ? "/mi" : "/km" }

    static func pace(mps: Double, unit: UnitSystem) -> String {
        "\(paceValue(mps: mps, unit: unit)) \(paceUnitLabel(unit))"
    }

    /// Duration for a shared image: "2hr 4min", "8min", "45s".
    ///
    /// Not `HH:MM:SS`. A stopwatch readout is right while a ride is running, where the seconds are
    /// moving and you are watching them. On a finished ride it asks the reader to parse `00:13:06`
    /// into "thirteen minutes" — three fields, two of them usually zero, in the one place the
    /// picture has least room and least of the reader's attention.
    ///
    /// Mirrors Android's `compactDuration` exactly, including the sub-minute case: a blank where a
    /// duration should be reads as a bug rather than as a very short ride.
    static func shareDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 && minutes > 0 { return "\(hours)hr \(minutes)min" }
        if hours > 0 { return "\(hours)hr" }
        if minutes > 0 { return "\(minutes)min" }
        return "\(secs)s"
    }
}
