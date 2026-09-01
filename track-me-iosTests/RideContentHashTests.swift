import XCTest
@testable import track_me_ios

/// TASK-275: identity by track content, so the duplicate checks cannot be edited around.
///
/// Mirrors the Android suite case for case. The canonical form is byte-identical across the two
/// platforms, so a ride recorded on one and synced to the other resolves to the same identity.
final class RideContentHashTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double, _ secondsFromEpoch: TimeInterval,
                       speed: Double = 0, altitude: Double = 0) -> GPSPoint {
        GPSPoint(
            latitude: lat,
            longitude: lon,
            altitude: altitude,
            accuracy: 0,
            speed: speed,
            timestamp: Date(timeIntervalSince1970: secondsFromEpoch),
            isPaused: false
        )
    }

    private var track: [GPSPoint] {
        [
            point(12.97160, 77.59460, 1_000),
            point(12.97250, 77.59530, 1_010),
            point(12.97340, 77.59610, 1_020),
        ]
    }

    func testSameTrackHashesTheSame() {
        XCTAssertEqual(RideContentHash.of(track), RideContentHash.of(track))
    }

    func testADifferentRideHashesDifferently() {
        let later = track.map {
            point($0.latitude, $0.longitude, $0.timestamp.timeIntervalSince1970 + 3_600)
        }
        XCTAssertNotEqual(RideContentHash.of(track), RideContentHash.of(later))
    }

    func testPointOrderDoesNotChangeIdentity() {
        XCTAssertEqual(RideContentHash.of(track), RideContentHash.of(track.reversed()))
    }

    func testRecomputedFieldsDoNotChangeIdentity() {
        // Speed, accuracy and altitude are what another tool is most likely to recompute or drop.
        let stripped = track.map {
            point($0.latitude, $0.longitude, $0.timestamp.timeIntervalSince1970,
                  speed: 9.9, altitude: 812.5)
        }
        XCTAssertEqual(RideContentHash.of(track), RideContentHash.of(stripped))
    }

    func testALossyGPXRoundTripDoesNotChangeIdentity() {
        // The case that failed on an Android device: exporting to six-decimal GPX and importing
        // back tips points sitting near a rounding boundary. Hashing every coordinate made one
        // flipped point change the whole digest, so the re-import went unrecognised.
        let roundTripped = track.enumerated().map { index, original -> GPSPoint in
            let nudge = index.isMultiple(of: 3) ? 0.0000006 : -0.0000004
            return point(original.latitude + nudge,
                         original.longitude - nudge,
                         original.timestamp.timeIntervalSince1970)
        }
        XCTAssertEqual(RideContentHash.of(track), RideContentHash.of(roundTripped))
    }

    func testARideElsewhereAtTheSameInstantsIsNotTheSameRide() {
        let elsewhere = track.map {
            point($0.latitude + 0.5, $0.longitude + 0.5, $0.timestamp.timeIntervalSince1970)
        }
        XCTAssertNotEqual(RideContentHash.of(track), RideContentHash.of(elsewhere))
    }

    func testADifferentNumberOfSamplesIsADifferentTrack() {
        XCTAssertNotEqual(RideContentHash.of(track), RideContentHash.of(Array(track.dropLast())))
    }

    func testAMidTrackDeviationIsNotDistinguishedAndThatIsTheTrade() {
        // Honest about the limit, as on Android. Identity is sample count, instants and endpoints,
        // so two rides starting and finishing within the same 110 m, with the same number of
        // samples at the same instants, read as one ride even if the middle differs. Reaching that
        // by accident is not plausible; ruling it out by hashing every coordinate is what broke the
        // export-and-reimport case this exists to catch.
        var detour = track
        detour[1] = point(12.99000, detour[1].longitude, detour[1].timestamp.timeIntervalSince1970)
        XCTAssertEqual(RideContentHash.of(track), RideContentHash.of(detour))
    }

    func testTooShortToIdentifyReturnsNil() {
        XCTAssertNil(RideContentHash.of([]))
        XCTAssertNil(RideContentHash.of([track[0]]))
    }

    func testProvenanceGatesProgress() {
        XCTAssertTrue(RideSource.earnsProgress(RideSource.recorded))
        XCTAssertFalse(RideSource.earnsProgress(RideSource.imported))
        // An unknown future value earns nothing rather than crashing or counting.
        XCTAssertFalse(RideSource.earnsProgress("SOMETHING_NEW"))
        XCTAssertFalse(RideSource.earnsProgress(nil))
    }
}
