import XCTest
@testable import track_me_ios

final class ExportPreviewPrivacyTests: XCTestCase {
    private func point(_ index: Int) -> GPSPoint {
        GPSPoint(latitude: 0, longitude: Double(index) * 0.001, altitude: 0,
                 accuracy: 1, speed: 1, timestamp: Date(timeIntervalSince1970: Double(index)))
    }

    func testRenderPointsUsesToggleAndPreservesChronologicalOrder() {
        let points = (0..<6).reversed().map(point)
        let trimmed = ExportPreviewView.renderPoints(Array(points), privacyTrim: true, trimMeters: 100)
        let untrimmed = ExportPreviewView.renderPoints(Array(points), privacyTrim: false, trimMeters: 100)

        XCTAssertEqual(untrimmed.map(\.id), points.reversed().map(\.id))
        XCTAssertLessThan(trimmed.count, untrimmed.count)
        XCTAssertGreaterThan(trimmed.first!.longitude, untrimmed.first!.longitude)
        XCTAssertLessThan(trimmed.last!.longitude, untrimmed.last!.longitude)
    }
}
