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

/// Presentation text is resolved by the view layer and passed into the renderer.
struct ReplayOverlay {
    var personaLabel: String? = nil
    var imperialUnits: Bool = false
}
