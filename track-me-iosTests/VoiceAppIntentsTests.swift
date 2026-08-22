import AppIntents
import XCTest
@testable import track_me_ios

@MainActor
final class VoiceAppIntentsTests: XCTestCase {
    func testRidePersonaAppEnumPreservesWireValues() {
        XCTAssertEqual(
            RidePersona.allCases.map(\.rawValue),
            ["AUTO", "WALK", "RUN", "CYCLING", "BIKE_DRIVE", "CAR_DRIVE"]
        )
        XCTAssertEqual(Set(RidePersona.caseDisplayRepresentations.keys), Set(RidePersona.allCases))
    }

    func testEveryIntentRunsHeadlessAndPersonalIntentsAllowLockedPhone() {
        XCTAssertEqual(TrackMeAppShortcuts.appShortcuts.count, 7)

        XCTAssertEqual(StartRideIntent.supportedModes, .background)
        XCTAssertEqual(PauseRideIntent.supportedModes, .background)
        XCTAssertEqual(ResumeRideIntent.supportedModes, .background)
        XCTAssertEqual(EndRideIntent.supportedModes, .background)
        XCTAssertEqual(RideDistanceIntent.supportedModes, .background)
        XCTAssertEqual(RidePaceIntent.supportedModes, .background)
        XCTAssertEqual(RideDurationIntent.supportedModes, .background)

        XCTAssertFalse(StartRideIntent.openAppWhenRun)
        XCTAssertFalse(PauseRideIntent.openAppWhenRun)
        XCTAssertFalse(ResumeRideIntent.openAppWhenRun)
        XCTAssertFalse(EndRideIntent.openAppWhenRun)
        XCTAssertFalse(RideDistanceIntent.openAppWhenRun)
        XCTAssertFalse(RidePaceIntent.openAppWhenRun)
        XCTAssertFalse(RideDurationIntent.openAppWhenRun)

        XCTAssertEqual(RideDistanceIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(RidePaceIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(RideDurationIntent.authenticationPolicy, .alwaysAllowed)
    }

    func testStartIntentPerformsWithExactPersonaAndTelemetry() async throws {
        let environment = FakeVoiceIntentEnvironment(snapshot: .idle)
        var intent = StartRideIntent()
        intent.persona = .run

        let response = try await intent.perform(environment: environment)

        XCTAssertEqual(environment.startedPersonas, [.run])
        XCTAssertEqual(response, .success("Run recording started."))
        XCTAssertEqual(environment.events, [
            VoiceTelemetryContract.commandInvoked(intent: .start, surface: .assistant)
        ])
    }

    func testStartFailureDoesNotClaimSuccess() async throws {
        let environment = FakeVoiceIntentEnvironment(snapshot: .idle)
        environment.startSucceeds = false
        var intent = StartRideIntent()
        intent.persona = .cycling

        let response = try await intent.perform(environment: environment)

        XCTAssertEqual(response.failureReason, .unavailable)
        XCTAssertEqual(environment.startedPersonas, [.cycling])
        XCTAssertEqual(environment.events.map(\.name), [
            "voice_command_invoked",
            "voice_command_failed"
        ])
    }

    func testPauseAndResumeNeverStartAMissingRide() async throws {
        let environment = FakeVoiceIntentEnvironment(snapshot: .idle)

        let pause = try await PauseRideIntent().perform(environment: environment)
        let resume = try await ResumeRideIntent().perform(environment: environment)

        XCTAssertEqual(pause.failureReason, .noActiveRide)
        XCTAssertEqual(resume.failureReason, .noActiveRide)
        XCTAssertEqual(environment.pauseCount, 0)
        XCTAssertEqual(environment.resumeCount, 0)
        XCTAssertTrue(environment.startedPersonas.isEmpty)
    }

    func testPauseAndResumePerformOnlyFromTheirValidStates() async throws {
        let environment = FakeVoiceIntentEnvironment(snapshot: .active(state: .tracking))
        let paused = try await PauseRideIntent().perform(environment: environment)
        XCTAssertEqual(paused, .success("Ride paused."))
        XCTAssertEqual(environment.pauseCount, 1)

        environment.snapshot = .active(state: .paused)
        let resumed = try await ResumeRideIntent().perform(environment: environment)
        XCTAssertEqual(resumed, .success("Ride resumed."))
        XCTAssertEqual(environment.resumeCount, 1)

        environment.snapshot = .active(state: .storageLow)
        let rejected = try await ResumeRideIntent().perform(environment: environment)
        XCTAssertEqual(rejected.failureReason, .invalidRideState)
        XCTAssertEqual(environment.resumeCount, 1)
    }

    func testEndPerformsOnlyAfterConfirmation() async throws {
        let rideID = UUID()
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(
                rideID: rideID,
                state: .tracking,
                distanceMeters: 12_400,
                movingDurationMillis: 58 * 60 * 1_000
            )
        )
        var confirmationDialog: String?

        let response = try await EndRideIntent().perform(
            environment: environment,
            unit: .metric,
            confirm: { dialog in
                XCTAssertEqual(environment.endCount, 0)
                confirmationDialog = dialog
            }
        )

        XCTAssertEqual(
            confirmationDialog,
            "You've recorded twelve point four kilometres in fifty-eight minutes. End the ride?"
        )
        XCTAssertEqual(environment.endCount, 1)
        XCTAssertEqual(response, .success("Ride saved."))
    }

    func testEndConfirmationCancellationLeavesRideRecording() async {
        let environment = FakeVoiceIntentEnvironment(snapshot: .active(state: .tracking))

        do {
            _ = try await EndRideIntent().perform(
                environment: environment,
                unit: .metric,
                confirm: { _ in throw CancellationError() }
            )
            XCTFail("A cancelled confirmation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(environment.endCount, 0)
            XCTAssertTrue(environment.snapshot.hasActiveRide)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLateEndConfirmationCannotStopAReplacementRide() async throws {
        let originalRideID = UUID()
        let replacementRideID = UUID()
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(rideID: originalRideID, state: .tracking)
        )

        let response = try await EndRideIntent().perform(
            environment: environment,
            unit: .metric,
            confirm: { _ in
                environment.snapshot = .active(rideID: replacementRideID, state: .tracking)
            }
        )

        XCTAssertEqual(response.failureReason, .invalidRideState)
        XCTAssertEqual(environment.endCount, 0)
        XCTAssertEqual(environment.snapshot.rideID, replacementRideID)
    }

    func testPersonalDistanceScriptsCoverMovingPausedGpsLostAndImperial() {
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(state: .tracking, distanceMeters: 12_400)
        )
        let intent = RideDistanceIntent()

        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "twelve point four kilometres so far."
        )

        environment.snapshot = .active(state: .paused, distanceMeters: 12_400)
        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "twelve point four kilometres. Your ride is paused."
        )

        environment.snapshot = .active(state: .gpsLost, distanceMeters: 12_400)
        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "twelve point four kilometres. I'm still looking for GPS, so that may be behind."
        )

        environment.snapshot = .active(state: .tracking, distanceMeters: 1_609.344)
        XCTAssertEqual(intent.perform(environment: environment, unit: .imperial).dialog, "one mile so far.")
    }

    func testPersonalPaceUsesPersonaRuleAndSpokenUnits() {
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(
                state: .tracking,
                persona: .run,
                speedMps: 1_000.0 / 372.0
            )
        )
        let intent = RidePaceIntent()

        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "six minutes twelve seconds per kilometre."
        )

        environment.snapshot = .active(
            state: .tracking,
            persona: .cycling,
            speedMps: 24.3 / 3.6
        )
        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "twenty-four point three kilometres per hour."
        )
    }

    func testPersonalDurationReportsMovingOrPaused() {
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(state: .tracking, movingDurationMillis: 58 * 60 * 1_000)
        )
        let intent = RideDurationIntent()

        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "fifty-eight minutes, moving."
        )

        environment.snapshot = .active(state: .paused, movingDurationMillis: 58 * 60 * 1_000)
        XCTAssertEqual(
            intent.perform(environment: environment, unit: .metric).dialog,
            "fifty-eight minutes, paused."
        )
    }

    func testPersonalQueryWithoutRideReturnsSpecifiedLineAndFailureTelemetry() {
        let environment = FakeVoiceIntentEnvironment(snapshot: .idle)

        let response = RideDistanceIntent().perform(environment: environment, unit: .metric)

        XCTAssertEqual(response.dialog, "You don't have a ride recording right now.")
        XCTAssertEqual(response.failureReason, .noActiveRide)
        XCTAssertEqual(environment.events, [
            VoiceTelemetryContract.commandInvoked(intent: .personalDistance, surface: .assistant),
            VoiceTelemetryContract.commandFailed(intent: .personalDistance, reason: .noActiveRide)
        ])
    }

    func testPersonalQueryTelemetryMarksGpsLostAnswerUnknown() {
        let environment = FakeVoiceIntentEnvironment(
            snapshot: .active(state: .gpsLost, distanceMeters: 12_400)
        )

        _ = RideDistanceIntent().perform(environment: environment, unit: .metric)

        XCTAssertEqual(environment.events, [
            VoiceTelemetryContract.commandInvoked(intent: .personalDistance, surface: .assistant),
            VoiceTelemetryContract.queryAnswered(intent: .personalDistance, freshness: .unknown)
        ])
    }
}

@MainActor
private final class FakeVoiceIntentEnvironment: VoiceIntentEnvironment {
    var snapshot: VoiceRideSnapshot
    var startSucceeds = true
    var startedPersonas: [RidePersona] = []
    var pauseCount = 0
    var resumeCount = 0
    var endCount = 0
    var events: [VoiceTelemetryEvent] = []

    init(snapshot: VoiceRideSnapshot) {
        self.snapshot = snapshot
    }

    var rideSnapshot: VoiceRideSnapshot { snapshot }

    func startRide(persona: RidePersona) -> Bool {
        startedPersonas.append(persona)
        return startSucceeds
    }

    func pauseRide() {
        pauseCount += 1
    }

    func resumeRide() {
        resumeCount += 1
    }

    func endRide() {
        endCount += 1
    }

    func trackVoiceEvent(_ event: VoiceTelemetryEvent) {
        events.append(event)
    }
}

private extension VoiceRideSnapshot {
    static let idle = VoiceRideSnapshot(
        rideID: nil,
        state: .idle,
        persona: .auto,
        distanceMeters: 0,
        speedMps: 0,
        movingDurationMillis: 0
    )

    static func active(
        rideID: UUID = UUID(),
        state: TrackingState,
        persona: RidePersona = .cycling,
        distanceMeters: Double = 0,
        speedMps: Double = 0,
        movingDurationMillis: TimeInterval = 0
    ) -> VoiceRideSnapshot {
        VoiceRideSnapshot(
            rideID: rideID,
            state: state,
            persona: persona,
            distanceMeters: distanceMeters,
            speedMps: speedMps,
            movingDurationMillis: movingDurationMillis
        )
    }
}
