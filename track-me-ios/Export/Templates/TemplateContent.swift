import Foundation

/// What a supporting figure is, so a template can place or drop it by meaning, not position.
nonisolated enum FigureRole: Equatable { case duration, elevation, effort }

/// One supporting figure: a quiet label and its value, both already localised and formatted.
nonisolated struct TemplateFigure: Equatable {
    let role: FigureRole
    let label: String
    let value: String
}

/// The Award's words, already chosen and localised; `facts` is what the ring is drawn from.
nonisolated struct AwardText: Equatable {
    let facts: AwardFacts
    let badge: String
    let badgeCaption: String
    let headline: String
    let subline: String?
}

/// Everything a template draws, as finished text and geometry — decided by the caller, never by the
/// renderer (`EXPORT_SHARE_CONTRACTS.md` §4). The twin of Android's `TemplateContent`.
nonisolated struct TemplateContent {
    var runs: [[TemplateCoordinate]]
    var joins: [[TemplateCoordinate]]
    /// Per point of each run, 0…1 pace intensity; nil or mismatched means one flat colour.
    var runIntensities: [[Float]]?
    var heroValue: String
    var heroUnit: String
    var heroUnitLong: String
    var figures: [TemplateFigure]
    var dateLine: String
    var placeLine: String?
    var link: String?
    var elevation: TemplateAnalytics.ElevationProfile?
    var elevationLabel: String?
    var splits: [TemplateAnalytics.SplitBar]
    var splitsLabel: String?
    var fastestSegment: [TemplateCoordinate]?
    var fastestLabel: String?
    var award: AwardText?
    var light: LightPhase
    var lightLine: String?
}
