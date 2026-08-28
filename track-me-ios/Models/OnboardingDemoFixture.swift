import Foundation
import CoreLocation

/// Canonical ride used by the onboarding demos and the first-run sample ride.
///
/// The route is now a **real recording** rather than a synthetic drawing: a Cycling ride captured on
/// the iOS Simulator against Apple's "City Bicycle Ride" location scenario through Cupertino, read
/// from `demo_ride.gpx`. The same file ships on Android, so both platforms show the identical route.
///
/// Two honest limitations of that recording, both visible in the demo:
///
///  - **There is no elevation.** The scenario supplies no terrain, so every point sits at 0 m and the
///    elevation trace renders flat. `CombinedMetricLineChart` already guards a zero altitude range,
///    so this degrades rather than divides by zero. Speed is real and varied, so the chart still
///    carries information.
///  - **The scenario loops every 15.6 minutes**, so the back half of the ride retraces the front
///    half. Real enough — cyclists do laps — but the map trail overlaps itself.
///
/// The returned SwiftData model graph is deliberately detached from every `ModelContext`.
enum OnboardingDemoFixture {
    static let referenceStartTime = Date(timeIntervalSince1970: 1_767_225_600)

    /// Parsed once, on first touch. `static let` is lazy and thread-safe in Swift, which is what
    /// lets the ~1,300-point file back this type without changing its Context-free API.
    private static let track = DemoRideGPX.load()

    static var duration: TimeInterval { track.duration }
    static var distanceMeters: Double { track.distanceMeters }
    static var averageSpeedMetersPerSecond: Double { track.averageSpeedMetersPerSecond }
    static var maxSpeedMetersPerSecond: Double { track.maxSpeedMetersPerSecond }
    static var pointCount: Int { track.points.count }

    /// Builds a detached model graph. The caller supplies any user-facing title so it can be
    /// localized; `nil` lets the existing ride-title fallback render normally.
    ///
    /// Point timestamps are rebased onto `startTime` using each fix's recorded offset, so the real
    /// cadence — including the pauses at junctions — survives being replayed at any date.
    static func makeRide(
        startTime: Date = referenceStartTime,
        title: String? = nil
    ) -> Ride {
        let source = track
        let ride = Ride(
            startTime: startTime,
            sourceInfo: "TrackMe Onboarding Sample",
            title: title
        )
        ride.endTime = startTime.addingTimeInterval(source.duration)
        ride.persona = RidePersona.cycling.rawValue
        ride.distanceMeters = source.distanceMeters
        ride.movingDurationMillis = Int64(source.duration * 1_000)
        ride.maxSpeedMps = source.maxSpeedMetersPerSecond
        ride.avgSpeedMps = source.averageSpeedMetersPerSecond
        ride.pointCount = source.points.count

        ride.points = source.points.map { sample in
            GPSPoint(
                latitude: sample.latitude,
                longitude: sample.longitude,
                altitude: sample.altitudeMeters,
                accuracy: sample.accuracyMeters,
                speed: sample.speedMetersPerSecond,
                timestamp: startTime.addingTimeInterval(sample.offset),
                ride: ride
            )
        }

        // TASK-248: the sample carries an elevation figure like any other ride. Every other
        // aggregate was set above and this one was not, so the sample — the first ride most riders
        // ever open — dropped its elevation cell while showing five populated neighbours.
        //
        // Measured rather than absent: this track has an altitude on every point and is genuinely
        // flat, so the answer is a real 0 m. §5.2 reserves the missing cell for altitude we never
        // had, which is a different claim from "it did not climb".
        ride.elevationGainMeters = RideMetrics.elevationGainMeters(from: ride.points ?? [])
        return ride
    }
}

/// Reads `demo_ride.gpx` out of the app bundle.
///
/// Deliberately separate from `GPXParser`: that type exists to import a user's file and rebuilds
/// speed from geometry, discarding accuracy. This one keeps the values the recorder actually wrote,
/// including the per-point speed carried in the Garmin `TrackPointExtension`.
enum DemoRideGPX {
    struct Sample {
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double
        let speedMetersPerSecond: Double
        let accuracyMeters: Double
        /// Seconds from the first fix, so the caller can rebase onto any start time.
        let offset: TimeInterval
    }

    struct Track {
        let points: [Sample]
        let duration: TimeInterval
        let distanceMeters: Double
        let maxSpeedMetersPerSecond: Double
        var averageSpeedMetersPerSecond: Double {
            duration > 0 ? distanceMeters / duration : 0
        }
    }

    static func load(resource: String = "demo_ride", ext: String = "gpx") -> Track {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("\(resource).\(ext) is missing from the app bundle")
            return Track(points: [], duration: 0, distanceMeters: 0, maxSpeedMetersPerSecond: 0)
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> Track {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        let sorted = delegate.raw.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last, sorted.count >= 2 else {
            return Track(points: [], duration: 0, distanceMeters: 0, maxSpeedMetersPerSecond: 0)
        }

        var distance = 0.0
        for index in 1..<sorted.count {
            let a = CLLocation(latitude: sorted[index - 1].lat, longitude: sorted[index - 1].lon)
            let b = CLLocation(latitude: sorted[index].lat, longitude: sorted[index].lon)
            distance += b.distance(from: a)
        }

        let base = first.time
        let points = sorted.map {
            Sample(
                latitude: $0.lat,
                longitude: $0.lon,
                altitudeMeters: $0.ele,
                speedMetersPerSecond: $0.speed,
                accuracyMeters: $0.hdop,
                offset: $0.time.timeIntervalSince(base)
            )
        }

        return Track(
            points: points,
            duration: last.time.timeIntervalSince(base),
            distanceMeters: distance,
            maxSpeedMetersPerSecond: points.map(\.speedMetersPerSecond).max() ?? 0
        )
    }

    fileprivate struct Raw {
        let lat: Double
        let lon: Double
        let ele: Double
        let speed: Double
        let hdop: Double
        let time: Date
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var raw: [Raw] = []

        private var text = ""
        private var lat = 0.0
        private var lon = 0.0
        private var ele = 0.0
        private var speed = 0.0
        private var hdop = 0.0
        private var time: Date?

        private static let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let plain: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            if elementName == "trkpt" {
                lat = Double(attributeDict["lat"] ?? "") ?? 0
                lon = Double(attributeDict["lon"] ?? "") ?? 0
                ele = 0; speed = 0; hdop = 0; time = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "ele": ele = Double(value) ?? 0
            case "hdop": hdop = Double(value) ?? 0
            case "speed", "gpxtpx:speed": speed = Double(value) ?? 0
            case "time": time = Self.fractional.date(from: value) ?? Self.plain.date(from: value)
            case "trkpt":
                if let time {
                    raw.append(Raw(lat: lat, lon: lon, ele: ele, speed: speed, hdop: hdop, time: time))
                }
            default: break
            }
        }
    }
}
