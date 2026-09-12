import Foundation

/// The light a ride happened in — what The Hour colours its frame by (SCOPE_1.8.9 §6.5). Boundaries
/// are the sun's elevation, not clock times: the same 06:14 is dark in a Delhi winter and broad
/// daylight in a Delhi summer. Identical to Android's `LightPhase`.
nonisolated enum LightPhase: String, CaseIterable {
    case dawn, goldenMorning, day, goldenEvening, dusk, night
}

/// Solar elevation from NOAA's general solar-position equations — the same source as the shipped
/// `SunsetCalculator`, for the same reasons: a date and a coarse position are all it needs. No
/// network, no permission, no third party receiving a location. The exact twin of Android's.
nonisolated enum SolarPhase {

    static func phase(latitude: Double, longitude: Double, at date: Date) -> LightPhase {
        let (elevation, morning) = position(latitude: latitude, longitude: longitude, at: date)
        if elevation < -6 { return .night }
        if elevation < 0 { return morning ? .dawn : .dusk }
        if elevation < 10 { return morning ? .goldenMorning : .goldenEvening }
        return .day
    }

    static func elevationDegrees(latitude: Double, longitude: Double, at date: Date) -> Double {
        position(latitude: latitude, longitude: longitude, at: date).elevation
    }

    private static func position(latitude: Double, longitude: Double, at date: Date) -> (elevation: Double, morning: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .hour, .minute, .second], from: date)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let daysInYear = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
        let hour = Double(parts.hour ?? 0)
        let minutes = hour * 60 + Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60

        let gamma = 2 * Double.pi / daysInYear * (dayOfYear - 1 + (hour - 12) / 24)
        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let trueSolarMinutes = minutes + equationOfTime + 4 * longitude
        let raw = (trueSolarMinutes / 4 - 180).truncatingRemainder(dividingBy: 360)
        let hourAngle = (raw + 540).truncatingRemainder(dividingBy: 360) - 180

        let latitudeRadians = latitude * .pi / 180
        let cosZenith = sin(latitudeRadians) * sin(declination)
            + cos(latitudeRadians) * cos(declination) * cos(hourAngle * .pi / 180)
        let elevation = 90 - acos(Swift.max(-1, Swift.min(1, cosZenith))) * 180 / .pi
        return (elevation, hourAngle < 0)
    }
}
