import XCTest
@testable import track_me_ios

final class GPXParserTests: XCTestCase {
    func testTrackMeIDExtraction() throws {
        let url = try temporaryGPX("<desc>TrackMeID:ABC-123</desc>")
        let parser = GPXParser()
        XCTAssertNotNil(parser.parse(url: url))
        XCTAssertEqual(parser.originalTrackMeId, "ABC-123")
    }

    func testNonTrackMeDescriptionIsIgnored() throws {
        let url = try temporaryGPX("<desc>Recorded with Foo</desc>")
        let parser = GPXParser()
        _ = parser.parse(url: url)
        XCTAssertNil(parser.originalTrackMeId)
    }

    private func temporaryGPX(_ metadata: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        let xml = """
        <?xml version="1.0"?><gpx><trk><name>Test</name>\(metadata)<trkseg><trkpt lat="1" lon="2"><time>2024-01-01T00:00:00Z</time></trkpt><trkpt lat="1.001" lon="2.001"><time>2024-01-01T00:00:01Z</time></trkpt></trkseg></trk></gpx>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
