import XCTest
@testable import track_me_ios

final class SupportDiagnosticsTests: XCTestCase {
    func testDiagnosticsContainContextButNoLocationOrRideData() {
        let rendered = SupportDiagnostics.render(SupportDiagnosticsInput(
            appVersion: "1.6.1 (42)", iosVersion: "18.6", device: "iPhone16,1",
            appLanguage: "en", deviceLocale: "en_US", units: "metric",
            locationAuthorization: "Always, precise", notificationAuthorization: "Granted",
            lowPowerMode: "disabled", backgroundRefresh: "Available", signedIn: false
        ))
        XCTAssertTrue(rendered.contains("App version: 1.6.1 (42)"))
        XCTAssertTrue(rendered.contains("Location authorization: Always, precise"))
        XCTAssertNil(rendered.range(of: #"-?\d{1,3}\.\d{4,}"#, options: .regularExpression))
        XCTAssertNil(rendered.range(of: #"(?i)\b(lat|lon|ride)\b"#, options: .regularExpression))
    }
}
