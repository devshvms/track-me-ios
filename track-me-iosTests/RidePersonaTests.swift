import XCTest
@testable import track_me_ios

final class RidePersonaTests: XCTestCase {
    func testWireValuesAndRoundTrip() {
        XCTAssertEqual(RidePersona.allCases.map(\.rawValue), ["AUTO", "WALK", "RUN", "CYCLING", "BIKE_DRIVE", "CAR_DRIVE"])
        for persona in RidePersona.allCases { XCTAssertEqual(RidePersona.fromStoredName(persona.rawValue), persona) }
    }
    func testUnknownValuesFallBackToAuto() {
        XCTAssertEqual(RidePersona.fromStoredName(nil), .auto)
        XCTAssertEqual(RidePersona.fromStoredName(""), .auto)
        XCTAssertEqual(RidePersona.fromStoredName("GARBAGE"), .auto)
        XCTAssertEqual(RidePersona.fromStoredName("cycling"), .auto)
    }
}
