import AppIntents

protocol TrackMeBackgroundIntent: AppIntent {}

extension TrackMeBackgroundIntent {
    /// iOS 26 replacement for `openAppWhenRun = false`.
    static var supportedModes: IntentModes { .background }

    /// Retained explicitly for the SCOPE_1.8.4 §3.2 invariant and older framework metadata.
    static var openAppWhenRun: Bool { false }

    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}

struct StartRideIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Start"

    @Parameter(title: "Mode", default: .auto)
    var persona: RidePersona

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await perform(environment: LiveVoiceIntentEnvironment.shared)
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment) async throws -> VoiceIntentResponse {
        try await VoiceActionIntentPerformer(environment: environment).perform(
            action: .start,
            persona: persona
        )
    }
}

struct PauseRideIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Pause tracking"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await perform(environment: LiveVoiceIntentEnvironment.shared)
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment) async throws -> VoiceIntentResponse {
        try await VoiceActionIntentPerformer(environment: environment).perform(action: .pause)
    }
}

struct ResumeRideIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Resume tracking"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await perform(environment: LiveVoiceIntentEnvironment.shared)
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment) async throws -> VoiceIntentResponse {
        try await VoiceActionIntentPerformer(environment: environment).perform(action: .resume)
    }
}

struct EndRideIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Stop tracking"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await perform(
            environment: LiveVoiceIntentEnvironment.shared,
            unit: UnitPreference.current,
            confirm: { dialog in
                try await requestConfirmation(
                    conditions: [],
                    actionName: .continue,
                    dialog: "\(dialog)"
                )
            }
        )
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(
        environment: any VoiceIntentEnvironment,
        unit: UnitSystem,
        confirm: @escaping (String) async throws -> Void
    ) async throws -> VoiceIntentResponse {
        try await VoiceActionIntentPerformer(environment: environment).perform(
            action: .end,
            unit: unit,
            confirm: confirm
        )
    }
}
