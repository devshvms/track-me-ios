import CoreGraphics
import Foundation

/// The five export templates (SCOPE_1.8.9 §6). Declaration order is the strip's order, and it is
/// stable: The Award sits last so its appearing and disappearing never moves the others.
nonisolated enum ExportTemplateID: String, CaseIterable, Identifiable {
    case trace, instrument, sticker, hour, award
    var id: String { rawValue }
    /// Telemetry identity — identical to Android's `analyticsValue`.
    var analyticsValue: String { rawValue }
}

/// §9.3 — forced by the data: an aggregate has no single reveal, split table or hour.
nonisolated enum TemplateScope { case single, aggregate, both }

/// The canvases a template is designed for, at the destination's real pixel size.
nonisolated enum TemplateCanvas: String, CaseIterable {
    case story, portrait, square, card

    var pixelSize: CGSize {
        switch self {
        case .story: return CGSize(width: 1080, height: 1920)
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .square: return CGSize(width: 1080, height: 1080)
        // The Sticker's own card: sized to its content, not to a destination frame.
        case .card: return CGSize(width: 1080, height: 675)
        }
    }

    var aspect: CGFloat { pixelSize.width / pixelSize.height }

    var label: String {
        switch self {
        case .story: return "9:16"
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .card: return ""
        }
    }
}

/// A template as data rather than as a renderer (SCOPE_1.8.9 §5).
nonisolated struct ExportTemplateSpec {
    let id: ExportTemplateID
    let scope: TemplateScope
    /// First is the default.
    let canvases: [TemplateCanvas]
    var transparent = false
    var supportsMapBackground = false
    var defaultCanvas: TemplateCanvas { canvases[0] }
}

nonisolated enum ExportTemplates {
    static let all: [ExportTemplateSpec] = [
        ExportTemplateSpec(id: .trace, scope: .both, canvases: [.story, .portrait, .square], supportsMapBackground: true),
        ExportTemplateSpec(id: .instrument, scope: .single, canvases: [.portrait, .square, .story]),
        ExportTemplateSpec(id: .sticker, scope: .both, canvases: [.card], transparent: true),
        ExportTemplateSpec(id: .hour, scope: .single, canvases: [.story, .portrait, .square]),
        ExportTemplateSpec(id: .award, scope: .single, canvases: [.story, .portrait, .square]),
    ]

    static func spec(_ id: ExportTemplateID) -> ExportTemplateSpec { all.first { $0.id == id }! }

    /// The canvas to render `id` at: the user's last choice when the template was designed for it,
    /// otherwise the template's own default. A template never renders at a ratio it was not made for.
    static func canvas(for id: ExportTemplateID, preferred: TemplateCanvas?) -> TemplateCanvas {
        let spec = spec(id)
        if let preferred, spec.canvases.contains(preferred) { return preferred }
        return spec.defaultCanvas
    }

    /// The ratios offered for `id`, in one fixed order for every template. The spec lists its native
    /// canvas first; chips that reshuffle under the thumb on each template change read as new options.
    static func canvasChoices(for id: ExportTemplateID) -> [TemplateCanvas] {
        TemplateCanvas.allCases.filter(spec(id).canvases.contains)
    }
}
