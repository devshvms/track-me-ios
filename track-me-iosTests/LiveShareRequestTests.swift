import XCTest
@testable import track_me_ios

final class LiveShareRequestTests: XCTestCase {
    func testLiveShareRequestSetsTimeout() {
        let url = URL(string: "https://example.com/x")!
        let req = LiveSharingManager.makeLiveShareRequest(url: url)
        XCTAssertEqual(req.timeoutInterval, 15, accuracy: 0.001)   // regression guard: never silently reverts to the 60s default
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}
