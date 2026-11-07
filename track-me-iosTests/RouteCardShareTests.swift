import XCTest
@testable import track_me_ios

final class RouteCardShareTests: XCTestCase {

    func testResolveShareChannel_mapsKnownActivityTypesCoarsely() {
        XCTAssertEqual(TelemetryManager.resolveShareChannel("net.whatsapp.WhatsApp.ShareExtension"), "whatsapp")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.burbn.instagram.shareextension"), "instagram")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("ph.telegra.Telegraph.Share"), "telegram")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.atebits.Tweetie2.ShareExtension"), "x")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.PostToTwitter"), "x")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.strava.stravalink"), "strava")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.PostToFacebook"), "facebook")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.Message"), "sms")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.Mail"), "email")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.AirDrop"), "airdrop")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.apple.UIKit.activity.CopyToPasteboard"), "copy")
        XCTAssertEqual(TelemetryManager.resolveShareChannel("com.unknown.random.share"), "other")
        XCTAssertEqual(TelemetryManager.resolveShareChannel(nil), "unknown")
        XCTAssertEqual(TelemetryManager.resolveShareChannel(""), "unknown")
    }

    func testReplayDeepLinkValidation() {
        XCTAssertTrue(ReplayDeepLink.isTrackMeLink("https://trackme.shvms.in/r/abc12345"))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink(nil))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink("https://trackme.shvms.in/r/"))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink("https://example.com/r/abc12345"))
    }
}
