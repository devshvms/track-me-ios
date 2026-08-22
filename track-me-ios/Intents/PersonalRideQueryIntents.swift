import AppIntents

struct RideDistanceIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Distance"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = perform(
            environment: LiveVoiceIntentEnvironment.shared,
            unit: UnitPreference.current
        )
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment, unit: UnitSystem) -> VoiceIntentResponse {
        VoicePersonalQueryIntentPerformer(environment: environment).perform(query: .distance, unit: unit)
    }
}

struct RidePaceIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Pace"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = perform(
            environment: LiveVoiceIntentEnvironment.shared,
            unit: UnitPreference.current
        )
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment, unit: UnitSystem) -> VoiceIntentResponse {
        VoicePersonalQueryIntentPerformer(environment: environment).perform(query: .paceOrSpeed, unit: unit)
    }
}

struct RideDurationIntent: TrackMeBackgroundIntent {
    static let title: LocalizedStringResource = "Duration"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = perform(
            environment: LiveVoiceIntentEnvironment.shared,
            unit: UnitPreference.current
        )
        return .result(dialog: "\(response.dialog)")
    }

    @MainActor
    func perform(environment: any VoiceIntentEnvironment, unit: UnitSystem) -> VoiceIntentResponse {
        VoicePersonalQueryIntentPerformer(environment: environment).perform(query: .duration, unit: unit)
    }
}
