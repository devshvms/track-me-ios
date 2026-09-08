import AppIntents

protocol TrackMeBackgroundIntent: AppIntent {}

extension TrackMeBackgroundIntent {
    /// iOS 26 replacement for `openAppWhenRun = false`.
    ///
    /// TASK-288: `IntentModes` does not exist before iOS 26, so this is availability-gated rather
    /// than unconditional. Nothing is lost below 26 — `openAppWhenRun` immediately below is the
    /// pre-26 spelling of the same intent, and it was already being kept deliberately.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    /// Retained explicitly for the SCOPE_1.8.4 §3.2 invariant and older framework metadata.
    /// On iOS 17–25 this is not a fallback but the only spelling, and it carries the invariant alone.
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
                // TASK-288. requestConfirmation(conditions:actionName:dialog:) is iOS 18+, so at a
                // 17.0 floor it needs the pre-18 spelling underneath it. The older overload is
                // deprecated on 18+, which is exactly why it is confined to the else branch.
                // Ending a ride must still ask — dropping the confirmation on iOS 17 rather than
                // porting it would silently make the destructive path one tap shorter there.
                if #available(iOS 18.0, *) {
                    try await requestConfirmation(
                        conditions: [],
                        actionName: .continue,
                        dialog: "\(dialog)"
                    )
                } else {
                    try await requestConfirmation(
                        result: .result(dialog: "\(dialog)"),
                        confirmationActionName: .continue
                    )
                }
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
