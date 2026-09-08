import Foundation

/// SCOPE_1.8.7 §6.1.6 scenario 28 — when the sun sets, computed on this device.
///
/// The iOS twin of `domain/notifications/SunsetCalculator.kt`, and asserted against the same real
/// sunsets for the same real places.
///
/// §6.1.6 calls this the best cost/value ratio in the release, and the reason is entirely about what
/// it does *not* need: sunset follows from a date and a coarse position the app already has. **No
/// network, no third-party API, no new permission, and no new party receiving location** — which is
/// what separates it from scenarios 29 and 30 (weather and AQI), both deferred precisely because
/// they need all four.
enum SunsetCalculator {

    /// The sun's centre this far below the horizon, allowing for refraction — the standard value.
    private static let zenithDegrees = 90.833

    /// Three hours. Long enough to cover the ride someone is about to start, short enough that the
    /// line only appears when it is genuinely a consideration.
    static let maxMinutesWorthMentioning = 180

    /// Minutes after local midnight at which the sun sets, or nil when it does not set that day.
    ///
    /// Nil is a real answer, not a failure: above the Arctic and below the Antarctic circle there
    /// are days with no sunset at all, and a caller that treats nil as "unknown" and shows nothing
    /// is behaving correctly for those users.
    static func sunsetMinutesAfterMidnight(
        latitude: Double,
        longitude: Double,
        dayOfYear: Int,
        utcOffsetMinutes: Int
    ) -> Int? {
        guard abs(latitude) <= 90, abs(longitude) <= 180, (1...366).contains(dayOfYear) else { return nil }

        let zenithRad = zenithDegrees * .pi / 180
        let latRad = latitude * .pi / 180

        // Approximate time, as a fraction of the day, for the *setting* event.
        let longitudeHour = longitude / 15.0
        let approximateTime = Double(dayOfYear) + ((18 - longitudeHour) / 24.0)

        let meanAnomaly = (0.9856 * approximateTime) - 3.289
        var trueLongitude = meanAnomaly
            + (1.916 * sin(meanAnomaly * .pi / 180))
            + (0.020 * sin(2 * meanAnomaly * .pi / 180))
            + 282.634
        trueLongitude = normalizeDegrees(trueLongitude)

        // Right ascension, forced into the same quadrant as the true longitude — the step that is
        // easiest to omit and produces an answer wrong by hours rather than minutes.
        var rightAscension = atan(0.91764 * tan(trueLongitude * .pi / 180)) * 180 / .pi
        rightAscension = normalizeDegrees(rightAscension)
        let longitudeQuadrant = (trueLongitude / 90.0).rounded(.down) * 90.0
        let rightAscensionQuadrant = (rightAscension / 90.0).rounded(.down) * 90.0
        rightAscension = (rightAscension + (longitudeQuadrant - rightAscensionQuadrant)) / 15.0

        let sinDeclination = 0.39782 * sin(trueLongitude * .pi / 180)
        let cosDeclination = cos(asin(sinDeclination))

        let cosHourAngle = (cos(zenithRad) - (sinDeclination * sin(latRad))) / (cosDeclination * cos(latRad))
        // Out of range means the sun never reaches the horizon that day: midnight sun, or polar
        // night. Both are "there is no sunset to report".
        guard (-1.0...1.0).contains(cosHourAngle) else { return nil }

        let hourAngle = (acos(cosHourAngle) * 180 / .pi) / 15.0
        let localMeanTime = hourAngle + rightAscension - (0.06571 * approximateTime) - 6.622
        let utcHours = normalizeHours(localMeanTime - longitudeHour)

        let localMinutes = (utcHours * 60.0) + Double(utcOffsetMinutes)
        // Wrap rather than clamp: a sunset can land on the adjacent calendar day in local time near
        // a date line or a large offset, and clamping would report midnight.
        let wrapped = localMinutes.truncatingRemainder(dividingBy: 1440)
        return Int(wrapped < 0 ? wrapped + 1440 : wrapped)
    }

    /// Minutes from now until sunset, or nil when there is nothing useful to say.
    ///
    /// Nil when the sun does not set, when it has already set, or when it is further away than
    /// `maxMinutesWorthMentioning`. Someone setting off at ten in the morning does not need to be
    /// told about sunset — the fact is true, and saying it is the app filling silence.
    static func minutesUntilSunset(
        latitude: Double,
        longitude: Double,
        dayOfYear: Int,
        minutesAfterLocalMidnightNow: Int,
        utcOffsetMinutes: Int
    ) -> Int? {
        guard let sunset = sunsetMinutesAfterMidnight(
            latitude: latitude, longitude: longitude,
            dayOfYear: dayOfYear, utcOffsetMinutes: utcOffsetMinutes
        ) else { return nil }
        let remaining = sunset - minutesAfterLocalMidnightNow
        guard remaining > 0, remaining <= maxMinutesWorthMentioning else { return nil }
        return remaining
    }

    /// The device's current UTC offset in minutes, DST included.
    static func utcOffsetMinutes(timeZone: TimeZone = .current, at date: Date = Date()) -> Int {
        timeZone.secondsFromGMT(for: date) / 60
    }

    private static func normalizeDegrees(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func normalizeHours(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 24)
        return wrapped < 0 ? wrapped + 24 : wrapped
    }
}
