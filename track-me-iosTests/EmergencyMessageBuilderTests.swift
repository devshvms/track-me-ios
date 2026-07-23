import XCTest
import CoreLocation
@testable import track_me_ios

final class EmergencyMessageBuilderTests: XCTestCase {

    let template = "EMERGENCY! I need help. My last known location is: [Location Link]. Battery: [Battery Percent]. Device: [Device Name]. Time: [Timestamp]"

    func testBuildEmergencyMessage_AllValuesPresent() {
        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        // 2026-07-24 10:00:00 UTC
        let date = Date(timeIntervalSince1970: 1784887200)

        let message = EmergencyManager.shared.buildEmergencyMessage(
            template: template,
            coordinate: coord,
            battery: 0.85,
            deviceModel: "iPhone 15 Pro",
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let expectedTime = formatter.string(from: date)

        let expected = "EMERGENCY! I need help. My last known location is: https://maps.google.com/?q=37.7749,-122.4194. Battery: 85%. Device: iPhone 15 Pro. Time: \(expectedTime)"

        XCTAssertEqual(message, expected)
    }

    func testBuildEmergencyMessage_MissingLocationAndBattery() {
        let date = Date(timeIntervalSince1970: 1784887200)

        let message = EmergencyManager.shared.buildEmergencyMessage(
            template: template,
            coordinate: nil,
            battery: -1.0,
            deviceModel: "iPad",
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let expectedTime = formatter.string(from: date)

        let expected = "EMERGENCY! I need help. My last known location is: Location unknown. Battery: Unknown. Device: iPad. Time: \(expectedTime)"

        XCTAssertEqual(message, expected)
    }

    func testBuildEmergencyMessage_LeavesUnknownTokensIntact() {
        let customTemplate = "Help! [Location Link] [Unknown Token]"
        let coord = CLLocationCoordinate2D(latitude: 0, longitude: 0)

        let message = EmergencyManager.shared.buildEmergencyMessage(
            template: customTemplate,
            coordinate: coord,
            battery: 1.0,
            deviceModel: "iPhone",
            date: Date()
        )

        XCTAssertEqual(message, "Help! https://maps.google.com/?q=0.0,0.0 [Unknown Token]")
    }
}
