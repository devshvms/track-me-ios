import XCTest
@testable import track_me_ios

final class SupportMailURLTests: XCTestCase {
    func testMailtoBodyRoundTripsReservedAndUnicodeCharacters() {
        let body = "line one\nline two & # + café 日本"
        var components = URLComponents(string: "mailto:\(SupportContact.email)")!
        components.queryItems = [URLQueryItem(name: "subject", value: "TrackMe support"), URLQueryItem(name: "body", value: body)]
        let url = try! XCTUnwrap(components.url)
        let roundTrip = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "body" })?.value
        XCTAssertEqual(roundTrip, body)
    }
}
