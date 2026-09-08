import Foundation

enum ReplayExportConfigError: Error, Equatable {
    case invalidDimensions
    case invalidFrameRate
    case invalidDuration
    case invalidPrivacyTrim
}

struct ReplayExportConfig {
    let width: Int
    let height: Int
    let fps: Int
    let targetDurationSeconds: Int
    let applyPrivacyTrim: Bool
    let privacyTrimDistanceMeters: Double
    let persona: RidePersona
    let deepLink: String?
    let overlay: ReplayOverlay

    init(
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        targetDurationSeconds: Int = 20,
        applyPrivacyTrim: Bool = true,
        privacyTrimDistanceMeters: Double = 200.0,
        persona: RidePersona,
        deepLink: String? = nil,
        overlay: ReplayOverlay = ReplayOverlay()
    ) throws {
        guard width > 0 && height > 0 else { throw ReplayExportConfigError.invalidDimensions }
        guard (1...60).contains(fps) else { throw ReplayExportConfigError.invalidFrameRate }
        guard (15...30).contains(targetDurationSeconds) else { throw ReplayExportConfigError.invalidDuration }
        guard privacyTrimDistanceMeters >= 0 else { throw ReplayExportConfigError.invalidPrivacyTrim }
        self.width = width
        self.height = height
        self.fps = fps
        self.targetDurationSeconds = targetDurationSeconds
        self.applyPrivacyTrim = applyPrivacyTrim
        self.privacyTrimDistanceMeters = privacyTrimDistanceMeters
        self.persona = persona
        self.deepLink = deepLink
        self.overlay = overlay
    }
}

struct ReplayStats {
    let distanceMeters: Double
    let durationMillis: Int64
    let averageSpeedMetersPerSecond: Double
}

/// Presentation text and chrome resolved by the view layer and passed into the renderer.
///
/// ### TASK-305: why the style fields are here
///
/// The still image and the video come from one preview with one set of toggles, and the video
/// honoured none of them. `Show date`, `Show duration`, `Show distance` and `Dark overlay` all
/// applied to the image and were silently ignored by the video made from the same screen.
///
/// [figures] carries the *already formatted* strings from `ExportOverlayContent.figures`, the same
/// values the image panel renders. Handing the renderer finished text is the same rule as
/// [personaLabel] and exists for the same reason: a second renderer deriving its own figures is
/// how the file comes to say something the preview did not.
///
/// The defaults describe an unstyled frame rather than the old hard-coded one, so a call site that
/// forgets to pass the user's choices produces a clean video rather than a wrong one.
struct ReplayOverlay {
    var personaLabel: String? = nil
    var imperialUnits: Bool = false
    /// Already-formatted figures, in display order. Empty means draw no panel.
    var figures: [String] = []
    /// The user's `Dark overlay` choice, applied to the burned-in chrome.
    var darkTheme: Bool = true

    /// True when there is something to put in a panel. An empty panel is a box on bare map.
    var drawsPanel: Bool { !figures.isEmpty }
}
