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

    func testQuickActivityModePolicyOrderSelectionAndTelemetryParity() {
        XCTAssertEqual(
            QuickActivityModePolicy.orderedPersonas,
            [.auto, .carDrive, .bikeDrive, .walk, .cycling, .run]
        )
        XCTAssertEqual(Set(QuickActivityModePolicy.orderedPersonas), Set(RidePersona.allCases))
        XCTAssertEqual(QuickActivityModePolicy.resolveTap(current: .auto, tapped: .cycling), .cycling)
        XCTAssertNil(QuickActivityModePolicy.resolveTap(current: .cycling, tapped: .cycling))

        let props = TelemetryManager.buildActivityModeChipSelectedProperties(
            persona: .bikeDrive,
            previousPersona: .auto
        )
        XCTAssertEqual(props, ["persona": "BIKE_DRIVE", "previous_persona": "AUTO"])
    }
}
