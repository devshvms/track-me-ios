import AppIntents

/// Zero-setup phrases available immediately after install. Every phrase includes the app-name
/// token, as required by App Shortcuts, and Start expands the shipped RidePersona AppEnum.
struct TrackMeAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRideIntent(),
            phrases: [
                "Start a ride with \(.applicationName)",
                "Start my \(\.$persona) with \(.applicationName)"
            ],
            shortTitle: "Start",
            systemImageName: "record.circle"
        )

        AppShortcut(
            intent: PauseRideIntent(),
            phrases: [
                "Pause my ride with \(.applicationName)",
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause tracking",
            systemImageName: "pause.circle"
        )

        AppShortcut(
            intent: ResumeRideIntent(),
            phrases: [
                "Resume my ride with \(.applicationName)",
                "Continue my ride with \(.applicationName)"
            ],
            shortTitle: "Resume tracking",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: EndRideIntent(),
            phrases: [
                "End my ride with \(.applicationName)",
                "Stop my ride with \(.applicationName)",
                "Finish my ride with \(.applicationName)"
            ],
            shortTitle: "Stop tracking",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: RideDistanceIntent(),
            phrases: [
                "How far have I gone with \(.applicationName)",
                "What's my distance in \(.applicationName)"
            ],
            shortTitle: "Distance",
            systemImageName: "point.topleft.down.to.point.bottomright.curvepath"
        )

        AppShortcut(
            intent: RidePaceIntent(),
            phrases: [
                "What's my pace in \(.applicationName)",
                "How fast am I going in \(.applicationName)"
            ],
            shortTitle: "Pace",
            systemImageName: "speedometer"
        )

        AppShortcut(
            intent: RideDurationIntent(),
            phrases: [
                "How long have I been riding with \(.applicationName)",
                "What's my ride time in \(.applicationName)"
            ],
            shortTitle: "Duration",
            systemImageName: "timer"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .teal }
}
