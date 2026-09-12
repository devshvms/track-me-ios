import CoreText
import UIKit

/// A lite basemap behind The Trace (SCOPE_1.8.9 §8): the snapshot, and where **MapKit** says the route
/// landed on it, in the image's own pixels — never re-derived (`EXPORT_SHARE_CONTRACTS.md`).
struct MapBackdrop {
    let image: UIImage
    let runs: [[CGPoint]]
    let joins: [[CGPoint]]
    /// Radii of the ellipse about the bottom-left corner, in image points, where the shade is lifted
    /// off Apple's mark.
    var attributionSize: CGSize = .zero
}

/// Brand tokens the templates draw with. Gold is `gold/earned` — semantic, never decoration (§6.4).
enum TemplateColors {
    static let cyan = UIColor(rgb: 0x29B6F6)
    static let gold = UIColor(rgb: 0xE9B44C)
    static let cyanPace: [UIColor] = [UIColor(rgb: 0x0E6E9E), UIColor(rgb: 0x29B6F6), UIColor(rgb: 0x8FE6FF)]
    static let goldPace: [UIColor] = [UIColor(rgb: 0x8A6416), UIColor(rgb: 0xE9B44C), UIColor(rgb: 0xF7D98E)]
}

/// The Hour's six skies — values identical to Android's `HourPalette`.
struct HourPalette {
    let sky: [UIColor]
    let route: UIColor
    let eyebrow: UIColor
    let hero: UIColor
    let unit: UIColor
    let body: UIColor
    let sun: UIColor
    let scrim: UIColor

    static func of(_ phase: LightPhase) -> HourPalette {
        func c(_ hex: UInt32) -> UIColor { UIColor(rgb: hex) }
        switch phase {
        case .dawn:
            return HourPalette(sky: [c(0x2A1E3C), c(0x5B3350), c(0xB0574B), c(0xE08A4C), c(0xF5B96E)],
                               route: c(0xFFF3E2), eyebrow: c(0xFFD9B0), hero: c(0xFFF6EC), unit: c(0xF0C79E), body: c(0xEBC4A2), sun: c(0xFFD9A0), scrim: c(0x12080A))
        case .goldenMorning, .goldenEvening:
            return HourPalette(sky: [c(0x35220F), c(0x7A4A1F), c(0xC9782E), c(0xEDA64A), c(0xF8CF7E)],
                               route: c(0xFFF6E6), eyebrow: c(0xFFE2B8), hero: c(0xFFF8EE), unit: c(0xF6D2A2), body: c(0xF0CFA6), sun: c(0xFFE6B0), scrim: c(0x140B04))
        case .day:
            return HourPalette(sky: [c(0x0B3552), c(0x1D628A), c(0x3F93BD), c(0x86C3DE), c(0xCFE8F2)],
                               route: c(0xFFFFFF), eyebrow: c(0xE3F4FF), hero: c(0xFFFFFF), unit: c(0xD6EBF7), body: c(0xD9ECF6), sun: c(0xFFF7D6), scrim: c(0x06121C))
        case .dusk:
            return HourPalette(sky: [c(0x1A1431), c(0x43285A), c(0x8E3A66), c(0xCF5F4E), c(0xEE9A58)],
                               route: c(0xFFF0E8), eyebrow: c(0xFFCDB8), hero: c(0xFFF4EE), unit: c(0xF2C2AE), body: c(0xEDBFA9), sun: c(0xFFC59A), scrim: c(0x10070E))
        case .night:
            return HourPalette(sky: [c(0x04070B), c(0x0A121C), c(0x10203A), c(0x15304F), c(0x1B3E62)],
                               route: c(0xBFE9FF), eyebrow: c(0x8FCFF0), hero: c(0xEAF6FF), unit: c(0x9CC3DA), body: c(0xA9C8DA), sun: c(0xDDE8F2), scrim: c(0x020409))
        }
    }
}

/// Interpolates across evenly spaced colour stops.
func lerpColor(_ stops: [UIColor], _ t: CGFloat) -> UIColor {
    guard stops.count > 1 else { return stops.first ?? .clear }
    let scaled = Swift.max(0, Swift.min(1, t)) * CGFloat(stops.count - 1)
    let index = Swift.min(Int(scaled), stops.count - 2)
    let f = scaled - CGFloat(index)
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    stops[index].getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    stops[index + 1].getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: a1 + (a2 - a1) * f)
}

/// The Trace's route box in design units — one table, read by the renderer and the map camera.
func traceRouteBoxDesign(_ canvas: TemplateCanvas) -> CGRect {
    switch canvas {
    case .portrait: return CGRect(x: 120, y: 90, width: 840, height: 550)
    case .square: return CGRect(x: 120, y: 70, width: 840, height: 400)
    default: return CGRect(x: 120, y: 250, width: 840, height: 830)
    }
}

/// Draws the five export templates (SCOPE_1.8.9 §6). The layouts are Android's `TemplateRenderer`
/// tables, unit for unit, on a 1080-wide design canvas scaled by the width rendered — so the same
/// ride exported on either phone is the same picture, and a preview is the export at a smaller size.
///
/// Renders at scale 1, so the output is exactly the canvas's pixel size on every device. The previous
/// still export was `350 pt × screen scale` — 1050 px on a 3× phone, 700 px on a 2× one (TASK-311).
enum TemplateRenderer {
    static let designWidth: CGFloat = 1080

    static func render(
        _ template: ExportTemplateID,
        canvas: TemplateCanvas,
        content: TemplateContent,
        widthPx: CGFloat? = nil,
        backdrop: MapBackdrop? = nil
    ) -> UIImage {
        let width = (widthPx ?? canvas.pixelSize.width).rounded()
        let height = (width / canvas.aspect).rounded(.down)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !ExportTemplates.spec(template).transparent
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let scope = TemplateDrawScope(context: context.cgContext, width: width, height: height, canvas: canvas)
            switch template {
            case .trace: scope.drawTrace(content, backdrop: backdrop)
            case .instrument: scope.drawInstrument(content)
            case .sticker: scope.drawSticker(content)
            case .hour: scope.drawHour(content)
            case .award: scope.drawAward(content)
            case .itinerary: scope.drawItinerary(content)
            }
        }
    }
}

private final class TemplateDrawScope {
    enum Align { case left, center, right }

    let context: CGContext
    let width: CGFloat
    let height: CGFloat
    let canvas: TemplateCanvas
    let u: CGFloat

    init(context: CGContext, width: CGFloat, height: CGFloat, canvas: TemplateCanvas) {
        self.context = context
        self.width = width
        self.height = height
        self.canvas = canvas
        self.u = width / TemplateRenderer.designWidth
    }

    var designHeight: CGFloat { height / u }
    func px(_ value: CGFloat) -> CGFloat { value * u }
    func box(_ rect: CGRect) -> CGRect { CGRect(x: px(rect.minX), y: px(rect.minY), width: px(rect.width), height: px(rect.height)) }

    // MARK: Type

    func font(_ size: CGFloat, weight: CGFloat, tabular: Bool = false) -> UIFont {
        let pointSize = px(size)
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        var descriptor = UIFontDescriptor(fontAttributes: [.family: "Inter", variation: [0x77676874: weight]])
        if tabular {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]]])
        }
        let inter = UIFont(descriptor: descriptor, size: pointSize)
        if inter.familyName == "Inter" { return inter }
        let fallback: UIFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular
        return UIFont.systemFont(ofSize: pointSize, weight: fallback)
    }

    func attributed(_ value: String, font: UIFont, color: UIColor, tracking: CGFloat = 0, shadow: NSShadow? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking * font.pointSize]
        if let shadow { attributes[.shadow] = shadow }
        return NSAttributedString(string: value, attributes: attributes)
    }

    /// Draws with its **baseline** at `baseline` (as Android does), shortened with an ellipsis until
    /// it fits `maxWidth` design units.
    func text(_ value: String?, x: CGFloat, baseline: CGFloat, font: UIFont, color: UIColor,
              tracking: CGFloat = 0, align: Align = .left, maxWidth: CGFloat? = nil, shadow: NSShadow? = nil) {
        guard var value, !value.isEmpty else { return }
        var string = attributed(value, font: font, color: color, tracking: tracking, shadow: shadow)
        if let maxWidth {
            let limit = px(maxWidth)
            while string.size().width > limit && value.count > 1 {
                value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
                string = attributed(value + "…", font: font, color: color, tracking: tracking, shadow: shadow)
            }
        }
        let measured = string.size().width
        let originX: CGFloat
        switch align {
        case .left: originX = px(x)
        case .center: originX = px(x) - measured / 2
        case .right: originX = px(x) - measured
        }
        UIGraphicsPushContext(context)
        string.draw(at: CGPoint(x: originX, y: px(baseline) - font.ascender))
        UIGraphicsPopContext()
    }

    func width(of value: String, font: UIFont, tracking: CGFloat = 0) -> CGFloat {
        attributed(value, font: font, color: .white, tracking: tracking).size().width
    }

    /// The largest size from `size` down to half of it at which `value` fits `maxWidth`.
    func shrinkToFit(_ value: String, size: CGFloat, maxWidth: CGFloat, weight: CGFloat, tracking: CGFloat = 0) -> UIFont {
        var current = size
        var candidate = font(current, weight: weight)
        while current > size * 0.5 && width(of: value, font: candidate, tracking: tracking) > px(maxWidth) {
            current *= 0.92
            candidate = font(current, weight: weight)
        }
        return candidate
    }

    func hero(_ value: String, unit: String, x: CGFloat, baseline: CGFloat, size: CGFloat, color: UIColor, unitColor: UIColor, maxWidth: CGFloat) {
        var heroSize = size
        func span() -> CGFloat {
            width(of: value, font: font(heroSize, weight: 760, tabular: true), tracking: -0.035)
                + px(heroSize * 0.08) + width(of: unit, font: font(heroSize * 0.29, weight: 500))
        }
        while heroSize > size * 0.5 && span() > px(maxWidth) { heroSize *= 0.93 }
        let heroFont = font(heroSize, weight: 760, tabular: true)
        text(value, x: x, baseline: baseline, font: heroFont, color: color, tracking: -0.035)
        let unitX = x + (width(of: value, font: heroFont, tracking: -0.035) + px(heroSize * 0.08)) / u
        text(unit, x: unitX, baseline: baseline, font: font(heroSize * 0.29, weight: 500), color: unitColor)
    }

    /// The largest size from `size` down to 60 % of it at which `value` fits `maxWidth` design units.
    func fitSize(_ value: String, size: CGFloat, maxWidth: CGFloat, weight: CGFloat, tracking: CGFloat = 0, tabular: Bool = false) -> CGFloat {
        var current = size
        while current > size * 0.6 && width(of: value, font: font(current, weight: weight, tabular: tabular), tracking: tracking) > px(maxWidth) {
            current *= 0.95
        }
        return current
    }

    func figureColumns(_ figures: [TemplateFigure], left: CGFloat, right: CGFloat, labels: CGFloat, values: CGFloat, valueSize: CGFloat, labelColor: UIColor, valueColor: UIColor) {
        let column = (right - left) / 3
        let shown = Array(figures.prefix(3))
        guard !shown.isEmpty else { return }
        // One size for the whole row, the largest at which every value fits its column: "15.5 km/h"
        // does not fit where "3:53 /km" does, and an ellipsis inside a number is not a figure.
        let labelSize = shown.map { fitSize($0.label, size: 28, maxWidth: column - 16, weight: 600, tracking: 0.12) }.min()!
        let valueFit = shown.map { fitSize($0.value, size: valueSize, maxWidth: column - 16, weight: 500, tabular: true) }.min()!
        for (index, figure) in shown.enumerated() {
            let x = left + column * CGFloat(index)
            text(figure.label, x: x, baseline: labels, font: font(labelSize, weight: 600), color: labelColor, tracking: 0.12, maxWidth: column - 16)
            text(figure.value, x: x, baseline: values, font: font(valueFit, weight: 500, tabular: true), color: valueColor, maxWidth: column - 16)
        }
    }

    // MARK: Ground

    func skyGradient(_ stops: [UIColor]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map(\.cgColor) as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width * 0.25, y: height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// The sky colour under `point`, along the same diagonal `skyGradient` draws.
    func skyAt(_ stops: [UIColor], _ point: CGPoint) -> UIColor {
        let dx = width * 0.25
        let dy = height
        return lerpColor(stops, (point.x * dx + point.y * dy) / (dx * dx + dy * dy))
    }

    func fadeToward(_ color: UIColor, fromY: CGFloat, bottomAlpha: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(bottomAlpha).cgColor] as CFArray,
                                        locations: nil) else { return }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: px(fromY), width: width, height: height - px(fromY)))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: px(fromY)), end: CGPoint(x: 0, y: height), options: [])
        context.restoreGState()
    }

    /// Erases the shade drawn so far in the current transparency layer, in an ellipse about `corner`:
    /// wholly out to 60 % of the radii, where the mark sits, then feathered so the corner has no edge.
    func liftShade(corner: CGPoint, radii: CGSize) {
        let erase = UIColor.black
        guard radii.width > 0, radii.height > 0,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [erase.cgColor, erase.cgColor, erase.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 0.6, 1]) else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.translateBy(x: corner.x, y: corner.y)
        context.scaleBy(x: radii.width, y: radii.height)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }

    func hairline(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat, color: UIColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: px(x0), y: px(y), width: px(x1 - x0), height: Swift.max(1, px(2))))
    }

    // MARK: Route

    func project(_ content: TemplateContent, into routeBox: CGRect) -> (runs: [[CGPoint]], joins: [[CGPoint]])? {
        guard let projection = RouteProjection.fit((content.runs + content.joins).flatMap { $0 }, in: routeBox) else { return nil }
        return (content.runs.map(projection.project), content.joins.map(projection.project))
    }

    /// Runs as strokes coloured along their length, joins as dots, and the ends different by
    /// construction — hollow start, solid finish — so direction reads without an arrow.
    /// `colorOfRun`, when given, is the colour of run *i* — one ride, one colour — and the pace
    /// gradient is not consulted for that run at all (SCOPE_1.8.9 Part 2 §9.3). A selection's lines
    /// say *which ride*; a single ride's line says *how fast*. Both cannot be true of one stroke.
    func route(_ runs: [[CGPoint]], joins: [[CGPoint]], intensities: [[Float]]?, stroke: CGFloat,
               colorAt: (CGFloat) -> UIColor, groundAt: (CGPoint) -> UIColor, hollowStart: Bool = true,
               colorOfRun: ((Int) -> UIColor)? = nil) {
        let strokePx = px(stroke)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(strokePx * 0.7)
        context.setStrokeColor(colorAt(CGFloat(TemplateAnalytics.flatPaceIntensity)).withAlphaComponent(120 / 255).cgColor)
        context.setLineDash(phase: 0, lengths: [0.1, strokePx * 1.8])
        for join in joins where join.count >= 2 {
            context.addLines(between: join)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(strokePx)
        for (index, run) in runs.enumerated() where run.count >= 2 {
            let fixed = colorOfRun?(index)
            let values = fixed != nil ? nil
                : intensities.flatMap { $0.indices.contains(index) ? $0[index] : nil }.flatMap { $0.count == run.count ? $0 : nil }
            let kept = TemplateGeometry.decimate(run, minStep: Swift.max(1, strokePx * 0.35))
            if let values, !values.allSatisfy({ $0 == values[0] }) {
                // Eased along the thinned line: raw per-sample pace flickers, and round caps of
                // alternating colours stack into beads.
                let eased = easeAlong(kept.map { values[$0] })
                for k in 1..<kept.count {
                    context.setStrokeColor(colorAt(CGFloat((eased[k - 1] + eased[k]) / 2)).cgColor)
                    context.move(to: run[kept[k - 1]])
                    context.addLine(to: run[kept[k]])
                    context.strokePath()
                }
            } else {
                context.setStrokeColor((fixed ?? colorAt(CGFloat(values?.first ?? TemplateAnalytics.flatPaceIntensity))).cgColor)
                context.addLines(between: kept.map { run[$0] })
                context.strokePath()
            }
        }
        context.restoreGState()
        guard let start = runs.first(where: { !$0.isEmpty })?.first, let finish = runs.last(where: { !$0.isEmpty })?.last else { return }
        // The start belongs to the first ride and the finish to the last, so with a palette each
        // marker takes its own line's colour rather than a gradient end that matches neither.
        let startColor = colorOfRun.map { $0(runs.firstIndex(where: { !$0.isEmpty }) ?? 0) } ?? colorAt(1)
        let marker = colorOfRun.map { $0(runs.lastIndex(where: { !$0.isEmpty }) ?? 0) } ?? colorAt(1)
        let ring = strokePx * 1.3
        let startRect = CGRect(x: start.x - ring, y: start.y - ring, width: ring * 2, height: ring * 2)
        if hollowStart {
            context.setFillColor(groundAt(start).cgColor)
            context.fillEllipse(in: startRect)
        }
        context.setStrokeColor(startColor.cgColor)
        context.setLineWidth(strokePx * 0.55)
        context.strokeEllipse(in: startRect)
        if !hollowStart {
            // On a ground nobody can know — the Sticker goes on someone's photo — the start is a ring
            // around a dot instead of a hole cut out of the line.
            let dot = strokePx * 0.5
            context.setFillColor(startColor.cgColor)
            context.fillEllipse(in: CGRect(x: start.x - dot, y: start.y - dot, width: dot * 2, height: dot * 2))
        }
        let finishRadius = strokePx * 1.05
        context.setFillColor(marker.cgColor)
        context.fillEllipse(in: CGRect(x: finish.x - finishRadius, y: finish.y - finishRadius, width: finishRadius * 2, height: finishRadius * 2))
    }

    private func easeAlong(_ values: [Float], radius: Int = 8) -> [Float] {
        values.indices.map { index in
            let slice = values[Swift.max(0, index - radius)...Swift.min(values.count - 1, index + radius)]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    /// The corner link on every artifact — Android's `drawArtifactLink`, metric for metric.
    func link(_ link: String?) {
        guard let link, ReplayDeepLink.isTrackMeLink(link) else { return }
        let shorter = Swift.min(width, height)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: 200 / 255)
        shadow.shadowBlurRadius = shorter * 0.004
        shadow.shadowOffset = .zero
        let linkFont = UIFont.systemFont(ofSize: shorter * 0.014)
        let string = attributed(link, font: linkFont, color: UIColor(white: 235 / 255, alpha: 200 / 255), shadow: shadow)
        let size = string.size()
        UIGraphicsPushContext(context)
        string.draw(at: CGPoint(x: width - shorter * 0.022 - size.width, y: height - shorter * 0.022 - linkFont.ascender))
        UIGraphicsPopContext()
    }

    // MARK: The Trace

    private struct TraceLayout {
        let place, hero, heroSize, hairline, labels, values, valueSize, date, stroke: CGFloat
    }

    private var traceLayout: TraceLayout {
        switch canvas {
        case .portrait: return TraceLayout(place: 732, hero: 925, heroSize: 220, hairline: 985, labels: 1050, values: 1112, valueSize: 52, date: 1195, stroke: 15)
        case .square: return TraceLayout(place: 552, hero: 720, heroSize: 190, hairline: 772, labels: 832, values: 890, valueSize: 48, date: 962, stroke: 14)
        // 9:16 keeps every figure inside the centre 1080 × 1480 that Instagram's chrome leaves clear.
        default: return TraceLayout(place: 1195, hero: 1415, heroSize: 250, hairline: 1480, labels: 1550, values: 1615, valueSize: 56, date: 1690, stroke: 16)
        }
    }

    func drawTrace(_ content: TemplateContent, backdrop: MapBackdrop?) {
        let layout = traceLayout
        let ground = UIColor(rgb: 0x0C151B)
        var geometry: (runs: [[CGPoint]], joins: [[CGPoint]])?
        if let backdrop {
            backdrop.image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            // Points, never `cgImage` pixels: MapKit may hand back 3× whatever was asked for, and the
            // first cut cropped the corner in pixels, magnifying a sliver and burying the mark.
            let sx = width / backdrop.image.size.width
            let sy = height / backdrop.image.size.height
            // "Lite shade": the map is texture, not subject. One layer, so it can be lifted off Apple's
            // mark — the attribution is required, and the veil and the fade would bury it.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(UIColor(red: 12 / 255, green: 18 / 255, blue: 24 / 255, alpha: 168 / 255).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            fadeToward(UIColor(rgb: 0x080D11), fromY: layout.place - 180, bottomAlpha: 225 / 255)
            if backdrop.attributionSize.width > 0 {
                liftShade(corner: CGPoint(x: 0, y: height),
                          radii: CGSize(width: backdrop.attributionSize.width * sx, height: backdrop.attributionSize.height * sy))
            }
            context.endTransparencyLayer()
            geometry = (backdrop.runs.map { $0.map { CGPoint(x: $0.x * sx, y: $0.y * sy) } },
                        backdrop.joins.map { $0.map { CGPoint(x: $0.x * sx, y: $0.y * sy) } })
        } else {
            skyGradient([UIColor(rgb: 0x101B23), UIColor(rgb: 0x080D11)])
            contours(hairline: layout.hairline)
            geometry = project(content, into: box(traceRouteBoxDesign(canvas)))
        }
        if let geometry {
            route(geometry.runs, joins: geometry.joins, intensities: content.runIntensities, stroke: layout.stroke,
                  colorAt: { lerpColor(TemplateColors.cyanPace, $0) }, groundAt: { _ in ground }, hollowStart: backdrop == nil,
                  colorOfRun: content.paletteColorOfRun())
        }
        text(content.placeLine, x: 120, baseline: layout.place, font: font(34, weight: 600), color: TemplateColors.cyan, tracking: 0.14, maxWidth: 840)
        hero(content.heroValue, unit: content.heroUnit, x: 120, baseline: layout.hero, size: layout.heroSize,
             color: UIColor(rgb: 0xF2F7FA), unitColor: UIColor(rgb: 0x5E7280), maxWidth: 840)
        hairline(120, 960, y: layout.hairline, color: UIColor(rgb: 0x1E2C36))
        figureColumns(content.figures, left: 120, right: 960, labels: layout.labels, values: layout.values, valueSize: layout.valueSize,
                      labelColor: UIColor(rgb: 0x5E7280), valueColor: UIColor(rgb: 0xC8D6DF))
        text(content.dateLine, x: 120, baseline: layout.date, font: font(28, weight: 500), color: UIColor(rgb: 0x52646F), tracking: 0.08, maxWidth: 840)
        link(content.link)
    }

    /// Three faint contour lines behind the figures — the only ornament, nodding at the subject.
    private func contours(hairline: CGFloat) {
        context.saveGState()
        context.setStrokeColor(UIColor(rgb: 0x182630).withAlphaComponent(150 / 255).cgColor)
        context.setLineWidth(px(2))
        for offset in [-230.0, -180.0, -130.0] as [CGFloat] {
            let y = hairline + offset
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: px(y)))
            path.addQuadCurve(to: CGPoint(x: px(540), y: px(y)), controlPoint: CGPoint(x: px(270), y: px(y - 26)))
            path.addQuadCurve(to: CGPoint(x: px(1080), y: px(y - 8)), controlPoint: CGPoint(x: px(810), y: px(y + 26)))
            context.addPath(path.cgPath)
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: The Instrument

    func drawInstrument(_ content: TemplateContent) {
        let ground = UIColor(rgb: 0x0A1014)
        context.setFillColor(ground.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let left: CGFloat = 70
        let right: CGFloat = 1010
        let dateBaseline = designHeight - 64
        let summaryBaseline = dateBaseline - 60
        var cursor = summaryBaseline - 120
        let section: CGFloat = canvas == .square ? 124 : 150
        var splitsTop: CGFloat?
        if !content.splits.isEmpty { splitsTop = cursor - section; cursor = splitsTop! - 22 }
        var elevationTop: CGFloat?
        if content.elevation != nil { elevationTop = cursor - section; cursor = elevationTop! - 22 }
        let gridTop: CGFloat = 40
        grid(left: left, top: gridTop, right: right, bottom: cursor)
        let routeBox = box(CGRect(x: left + 40, y: gridTop + 70, width: right - left - 80, height: cursor - 30 - (gridTop + 70)))
        if let geometry = project(content, into: routeBox) {
            route(geometry.runs, joins: geometry.joins, intensities: nil, stroke: 12,
                  colorAt: { _ in TemplateColors.cyan }, groundAt: { _ in ground })
        }
        if let segment = content.fastestSegment,
           let projection = RouteProjection.fit((content.runs + content.joins).flatMap { $0 }, in: routeBox) {
            let points = projection.project(segment)
            if points.count >= 2 {
                context.saveGState()
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setLineWidth(px(15))
                context.setStrokeColor(TemplateColors.gold.cgColor)
                context.addLines(between: points)
                context.strokePath()
                context.restoreGState()
                // A legend rather than a label on the line: a label beside a route collides with it
                // on half of all shapes, and gold is the only gold thing on the canvas.
                context.setFillColor(TemplateColors.gold.cgColor)
                context.fill(CGRect(x: px(left + 24), y: px(gridTop + 30), width: px(40), height: px(7)))
                text(content.fastestLabel, x: left + 78, baseline: gridTop + 44, font: font(26, weight: 600), color: TemplateColors.gold, tracking: 0.14, maxWidth: 600)
            }
        }
        let labelColor = UIColor(rgb: 0x53666F)
        if let top = elevationTop, let profile = content.elevation {
            text(content.elevationLabel, x: left, baseline: top + 26, font: font(26, weight: 600), color: labelColor, tracking: 0.14, maxWidth: right - left)
            elevationBand(profile, area: box(CGRect(x: left, y: top + 44, width: right - left, height: section - 44)))
        }
        if let top = splitsTop {
            text(content.splitsLabel, x: left, baseline: top + 26, font: font(26, weight: 600), color: labelColor, tracking: 0.14, maxWidth: right - left)
            splitBars(content.splits, area: box(CGRect(x: left, y: top + 44, width: right - left, height: section - 44)))
        }
        hero(content.heroValue, unit: content.heroUnit, x: left, baseline: summaryBaseline, size: 104,
             color: UIColor(rgb: 0xE6EDF3), unitColor: UIColor(rgb: 0x6E808C), maxWidth: 470)
        // Elevation already has its own band above; repeating it here is what overflowed the line.
        let figures = content.figures.filter { !($0.role == .elevation && content.elevation != nil) }.map(\.value).joined(separator: "  ·  ")
        // Shrunk to fit rather than cut: without a band the line carries elevation too, and
        // "19.7 k…" is not a speed.
        let figuresSize = fitSize(figures, size: 38, maxWidth: right - 560, weight: 500, tabular: true)
        text(figures, x: 560, baseline: summaryBaseline - 6, font: font(figuresSize, weight: 500, tabular: true), color: UIColor(rgb: 0xA9BAC5), maxWidth: right - 560)
        text(content.dateLine, x: left, baseline: dateBaseline, font: font(26, weight: 500), color: UIColor(rgb: 0x4E606C), tracking: 0.08, maxWidth: right - left)
        link(content.link)
    }

    private func grid(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        context.setFillColor(UIColor(rgb: 0x16222B).cgColor)
        let thickness = Swift.max(1, px(1.6))
        var x = left
        while x <= right + 0.5 { context.fill(CGRect(x: px(x), y: px(top), width: thickness, height: px(bottom - top))); x += 117.5 }
        var y = top
        while y <= bottom + 0.5 { context.fill(CGRect(x: px(left), y: px(y), width: px(right - left), height: thickness)); y += 117.5 }
    }

    private func elevationBand(_ profile: TemplateAnalytics.ElevationProfile, area: CGRect) {
        let n = profile.heights.count
        guard n >= 2 else { return }
        let step = area.width / CGFloat(n - 1)
        let points = profile.heights.enumerated().map { CGPoint(x: area.minX + step * CGFloat($0.offset), y: area.maxY - CGFloat($0.element) * area.height) }
        context.saveGState()
        context.setFillColor(UIColor(rgb: 0x132631).cgColor)
        context.addLines(between: points + [CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)])
        context.closePath()
        context.fillPath()
        context.setStrokeColor(UIColor(rgb: 0x2E7EA3).cgColor)
        context.setLineWidth(px(4))
        context.setLineJoin(.round)
        context.addLines(between: points)
        context.strokePath()
        context.restoreGState()
    }

    private func splitBars(_ bars: [TemplateAnalytics.SplitBar], area: CGRect) {
        guard !bars.isEmpty else { return }
        let gap = bars.count > 30 ? px(2) : px(6)
        let barWidth = Swift.max(px(2), (area.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
        let radius = Swift.min(barWidth / 2, px(4))
        for (index, bar) in bars.enumerated() {
            let x = area.minX + CGFloat(index) * (barWidth + gap)
            let top = area.maxY - CGFloat(bar.heightFraction) * area.height
            let base = bar.isFastest ? TemplateColors.gold : lerpColor([UIColor(rgb: 0x17394F), UIColor(rgb: 0x2E97C8)], CGFloat(bar.speedFraction))
            context.setFillColor((bar.isPartial ? base.withAlphaComponent(110 / 255) : base).cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: top, width: barWidth, height: area.maxY - top), cornerRadius: radius).cgPath)
            context.fillPath()
        }
    }

    // MARK: The Sticker

    func drawSticker(_ content: TemplateContent) {
        // Transparent outside the plate; the plate is translucent so white figures read on any photo.
        context.setFillColor(UIColor(red: 10 / 255, green: 15 / 255, blue: 19 / 255, alpha: 168 / 255).cgColor)
        context.addPath(UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: px(64)).cgPath)
        context.fillPath()
        if let geometry = project(content, into: box(CGRect(x: 60, y: 72, width: 380, height: 531))) {
            route(geometry.runs, joins: geometry.joins, intensities: content.runIntensities, stroke: 11,
                  colorAt: { lerpColor(TemplateColors.cyanPace, $0) }, groundAt: { _ in .clear }, hollowStart: false,
                  colorOfRun: content.paletteColorOfRun())
        }
        text(content.heroValue, x: 500, baseline: 262, font: font(170, weight: 760, tabular: true), color: .white, tracking: -0.035, maxWidth: 530)
        text(content.heroUnitLong, x: 506, baseline: 322, font: font(28, weight: 600), color: UIColor(rgb: 0xA9BCC7), tracking: 0.16, maxWidth: 520)
        hairline(500, 1010, y: 362, color: UIColor(rgb: 0x3E525E).withAlphaComponent(200 / 255))
        let valueFont = font(44, weight: 500, tabular: true)
        for (index, figure) in content.figures.prefix(2).enumerated() {
            let baseline = 440 + CGFloat(index) * 66
            text(figure.value, x: 500, baseline: baseline, font: valueFont, color: UIColor(rgb: 0xDCE7EE), maxWidth: 300)
            let valueWidth = width(of: figure.value, font: valueFont) / u
            text(figure.label, x: 500 + valueWidth + 18, baseline: baseline, font: font(24, weight: 600), color: UIColor(rgb: 0x8FA3B0),
                 tracking: 0.12, maxWidth: 1010 - (500 + valueWidth + 18))
        }
        text(content.placeLine ?? content.dateLine, x: 500, baseline: 585, font: font(26, weight: 500), color: UIColor(rgb: 0x8FA3B0), tracking: 0.06, maxWidth: 510)
        if let link = content.link, ReplayDeepLink.isTrackMeLink(link) {
            text(link, x: 1036, baseline: 640, font: UIFont.systemFont(ofSize: px(15)), color: UIColor(rgb: 0xA9BCC7).withAlphaComponent(210 / 255), align: .right)
        }
    }

    // MARK: The Itinerary

    private struct ItineraryLayout {
        let top, stopGap, nameSize, regionSize, hopSize, heroBaseline, heroSize, footer: CGFloat
    }

    private func itineraryLayout(stops: Int) -> ItineraryLayout {
        let base: ItineraryLayout
        switch canvas {
        case .portrait: base = ItineraryLayout(top: 250, stopGap: 190, nameSize: 62, regionSize: 25, hopSize: 38, heroBaseline: 1230, heroSize: 118, footer: 1300)
        case .square: base = ItineraryLayout(top: 210, stopGap: 150, nameSize: 52, regionSize: 22, hopSize: 32, heroBaseline: 960, heroSize: 96, footer: 1020)
        default: base = ItineraryLayout(top: 300, stopGap: 230, nameSize: 70, regionSize: 27, hopSize: 42, heroBaseline: 1700, heroSize: 140, footer: 1790)
        }
        guard stops >= 2 else { return base }

        // The chain must end clear of the hairline above the hero, not of the hero's baseline — and
        // the last stop is not its dot: a district line sits beneath the name, and that is what
        // actually collides. Reserving for the dot alone is what put "Nashik" through the figure.
        let hairlineY = base.heroBaseline - base.heroSize * 0.95
        let underLastStop = base.nameSize * 0.34 + base.regionSize * 1.5 + 36
        let available = hairlineY - base.top - underLastStop
        let natural = CGFloat(stops - 1) * base.stopGap

        if natural <= available {
            // Room to spare: centre the chain in the band rather than hanging it from the top, which
            // left a four-stop tour with a dead third of a frame under it.
            return ItineraryLayout(top: base.top + (available - natural) / 2, stopGap: base.stopGap, nameSize: base.nameSize,
                                   regionSize: base.regionSize, hopSize: base.hopSize, heroBaseline: base.heroBaseline,
                                   heroSize: base.heroSize, footer: base.footer)
        }

        // Too many stops for the natural pitch. Tighten the gap to exactly the band, and the type
        // with it, so the column stays balanced instead of names colliding at the new spacing.
        let squeeze = Swift.min(Swift.max(available / natural, 0.4), 1)
        return ItineraryLayout(top: base.top, stopGap: base.stopGap * squeeze, nameSize: base.nameSize * Swift.max(squeeze, 0.62),
                               regionSize: base.regionSize * Swift.max(squeeze, 0.7), hopSize: base.hopSize * Swift.max(squeeze, 0.7),
                               heroBaseline: base.heroBaseline, heroSize: base.heroSize, footer: base.footer)
    }

    /// The journey as a chain of named stops — the one template that exists because a *selection* can
    /// say something a single ride cannot (SCOPE_1.8.9 Part 2). Metric for metric with Android's
    /// `drawItinerary`; the layout arithmetic above is the same arithmetic, not a second guess at it.
    func drawItinerary(_ content: TemplateContent) {
        skyGradient([UIColor(rgb: 0x101A16), UIColor(rgb: 0x0C1410), UIColor(rgb: 0x080F0C)])
        // No tour, nothing to draw. The caller should not have offered this template at all, and a
        // half-drawn chain would assert a journey the selection is not.
        guard let itinerary = content.itinerary, !itinerary.stops.isEmpty else {
            text(content.heroValue, x: 80, baseline: 540, font: font(140, weight: 760, tabular: true), color: .white, tracking: -0.03)
            return
        }

        let layout = itineraryLayout(stops: itinerary.stops.count)
        let railX: CGFloat = 132
        let textX: CGFloat = 208
        let rail = UIColor(rgb: 0x20362C)
        let lastY = layout.top + CGFloat(itinerary.stops.count - 1) * layout.stopGap

        // The rail is drawn first and once, so the dots sit on a single continuous line rather than a
        // series of segments that betray any rounding between them.
        context.setFillColor(rail.cgColor)
        context.fill(CGRect(x: px(railX - 2.5), y: px(layout.top), width: px(5), height: px(lastY - layout.top)))

        for (index, stop) in itinerary.stops.enumerated() {
            let y = layout.top + CGFloat(index) * layout.stopGap
            let terminal = index == 0 || index == itinerary.stops.count - 1
            if index == 0 {
                // Hollow at the start, solid everywhere after: the same grammar the single-ride
                // templates use, so a rider reads direction without a legend.
                let radius = px(17)
                let rect = CGRect(x: px(railX) - radius, y: px(y) - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(UIColor(rgb: 0x101A16).cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(TemplateColors.cyan.cgColor)
                context.setLineWidth(px(7))
                context.strokeEllipse(in: rect)
            } else {
                let radius = px(terminal ? 17 : 13)
                context.setFillColor(TemplateColors.cyan.cgColor)
                context.fillEllipse(in: CGRect(x: px(railX) - radius, y: px(y) - radius, width: radius * 2, height: radius * 2))
            }

            let nameBaseline = y + layout.nameSize * 0.34
            text(stop.name, x: textX, baseline: nameBaseline, font: font(layout.nameSize, weight: 720),
                 color: UIColor(rgb: 0xEAF2ED), tracking: -0.02, maxWidth: 1080 - textX - 60)
            if let region = stop.region {
                text(region.uppercased(), x: textX, baseline: nameBaseline + layout.regionSize * 1.5,
                     font: font(layout.regionSize, weight: 600), color: UIColor(rgb: 0x6E8C7E), tracking: 0.14,
                     maxWidth: 1080 - textX - 60)
            }

            if index < itinerary.hops.count {
                text(Self.kilometres(itinerary.hops[index].distanceMeters), x: textX, baseline: y + layout.stopGap * 0.55,
                     font: font(layout.hopSize, weight: 600, tabular: true), color: TemplateColors.cyan, maxWidth: 300)
            }
        }

        hairline(80, 1000, y: layout.heroBaseline - layout.heroSize * 0.95, color: rail)
        let heroFont = font(layout.heroSize, weight: 760, tabular: true)
        text(content.heroValue, x: 80, baseline: layout.heroBaseline, font: heroFont, color: .white, tracking: -0.035)
        let heroWidth = width(of: content.heroValue, font: heroFont, tracking: -0.035) / u
        text(content.heroUnit, x: 80 + heroWidth + 24, baseline: layout.heroBaseline,
             font: font(layout.heroSize * 0.3, weight: 500), color: UIColor(rgb: 0x6E8C7E))
        // The date and the coverage share the footer: what the trip was, and what it crossed.
        let footer = [content.dateLine.isEmpty ? nil : content.dateLine, content.coverageLine]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        text(footer, x: 80, baseline: layout.footer, font: font(26, weight: 500), color: UIColor(rgb: 0x4E6B5E),
             tracking: 0.08, maxWidth: 900)
        if let url = content.link, ReplayDeepLink.isTrackMeLink(url) {
            text(url, x: 1000, baseline: layout.footer + 46, font: font(20, weight: 400),
                 color: UIColor(rgb: 0x6E8C7E).withAlphaComponent(200 / 255), align: .right)
        }
    }

    /// Whole kilometres, as Android's `formatKm`: a hop is a leg of a journey, not a measurement.
    private static func kilometres(_ meters: Double) -> String { "\(Int(meters / 1000)) km" }

    // MARK: The Award

    private struct AwardLayout {
        let ringY, ringR, badge, badgeSize, caption, headline, headlineSize, subline, sublineSize: CGFloat
        let route: CGRect
        let stroke, hairline, hero, heroSize, figure1, figure2, date: CGFloat
    }

    private var awardLayout: AwardLayout {
        switch canvas {
        case .portrait:
            return AwardLayout(ringY: 250, ringR: 125, badge: 276, badgeSize: 92, caption: 322, headline: 490, headlineSize: 86, subline: 548, sublineSize: 38,
                               route: CGRect(x: 170, y: 590, width: 740, height: 290), stroke: 13, hairline: 935, hero: 1100, heroSize: 160, figure1: 1045, figure2: 1100, date: 1200)
        case .square:
            return AwardLayout(ringY: 200, ringR: 100, badge: 222, badgeSize: 74, caption: 262, headline: 400, headlineSize: 76, subline: 452, sublineSize: 34,
                               route: CGRect(x: 200, y: 490, width: 680, height: 230), stroke: 12, hairline: 770, hero: 905, heroSize: 140, figure1: 860, figure2: 905, date: 985)
        default:
            return AwardLayout(ringY: 380, ringR: 165, badge: 404, badgeSize: 118, caption: 462, headline: 690, headlineSize: 100, subline: 760, sublineSize: 42,
                               route: CGRect(x: 150, y: 830, width: 780, height: 400), stroke: 14, hairline: 1300, hero: 1490, heroSize: 190, figure1: 1420, figure2: 1486, date: 1590)
        }
    }

    func drawAward(_ content: TemplateContent) {
        let layout = awardLayout
        skyGradient([UIColor(rgb: 0x1A1409), UIColor(rgb: 0x0D1116), UIColor(rgb: 0x080D11)])
        if let award = content.award {
            ring(award, layout: layout)
            // Shrunk to sit inside the ring: "PR" is two letters, its translations are not.
            text(award.badge, x: 540, baseline: layout.badge, font: shrinkToFit(award.badge, size: layout.badgeSize, maxWidth: layout.ringR * 1.45, weight: 760),
                 color: TemplateColors.gold, align: .center)
            text(award.badgeCaption, x: 540, baseline: layout.caption,
                 font: shrinkToFit(award.badgeCaption, size: 26, maxWidth: layout.ringR * 1.5, weight: 600, tracking: 0.16),
                 color: UIColor(rgb: 0x8C7440), tracking: 0.16, align: .center)
            text(award.headline, x: 540, baseline: layout.headline, font: font(layout.headlineSize, weight: 680), color: UIColor(rgb: 0xF5EFE0),
                 tracking: -0.02, align: .center, maxWidth: 960)
            text(award.subline, x: 540, baseline: layout.subline, font: font(layout.sublineSize, weight: 450), color: UIColor(rgb: 0x9A8A66), align: .center, maxWidth: 960)
        }
        if let geometry = project(content, into: box(layout.route)) {
            route(geometry.runs, joins: geometry.joins, intensities: content.runIntensities, stroke: layout.stroke,
                  colorAt: { lerpColor(TemplateColors.goldPace, $0) }, groundAt: { _ in UIColor(rgb: 0x0C1116) })
        }
        hairline(120, 960, y: layout.hairline, color: UIColor(rgb: 0x2A2312))
        hero(content.heroValue, unit: content.heroUnit, x: 120, baseline: layout.hero, size: layout.heroSize,
             color: UIColor(rgb: 0xF5EFE0), unitColor: UIColor(rgb: 0x8A7B5C), maxWidth: 490)
        let figureFont = font(40, weight: 500, tabular: true)
        if content.figures.count > 0 { text(content.figures[0].value, x: 640, baseline: layout.figure1, font: figureFont, color: UIColor(rgb: 0xB9AC8E), maxWidth: 320) }
        if content.figures.count > 1 { text(content.figures[1].value, x: 640, baseline: layout.figure2, font: figureFont, color: UIColor(rgb: 0xB9AC8E), maxWidth: 320) }
        text(content.dateLine, x: 120, baseline: layout.date, font: font(26, weight: 500), color: UIColor(rgb: 0x6B5C3C), tracking: 0.08, maxWidth: 840)
        link(content.link)
    }

    /// The ring is information: the muted arc is the old record as a share of this ride, the bright
    /// remainder the new ground. With no record to beat it closes in gold.
    private func ring(_ award: AwardText, layout: AwardLayout) {
        let center = CGPoint(x: px(540), y: px(layout.ringY))
        let radius = px(layout.ringR)
        context.saveGState()
        context.setStrokeColor(UIColor(rgb: 0x2A2312).cgColor)
        context.setLineWidth(px(4))
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setLineCap(.round)
        context.setLineWidth(px(10))
        func arc(from start: CGFloat, sweep: CGFloat, color: UIColor) {
            let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: start * .pi / 180, endAngle: (start + sweep) * .pi / 180, clockwise: true)
            context.setStrokeColor(color.cgColor)
            context.addPath(path.cgPath)
            context.strokePath()
        }
        if award.facts.previousBest == nil {
            arc(from: -90, sweep: 359.99, color: TemplateColors.gold)
        } else {
            let previous = 360 * CGFloat(Swift.max(0, Swift.min(0.97, award.facts.previousFraction)))
            arc(from: -90, sweep: previous, color: UIColor(rgb: 0x6E5220))
            arc(from: -90 + previous, sweep: 360 - previous, color: TemplateColors.gold)
        }
        context.restoreGState()
    }

    // MARK: The Hour

    private struct HourLayout {
        let route: CGRect
        let eyebrow, hero, heroSize, body, place, stroke: CGFloat
        let lowSun: (CGFloat, CGFloat, CGFloat)
        let highSun: (CGFloat, CGFloat, CGFloat)
    }

    private var hourLayout: HourLayout {
        switch canvas {
        case .portrait:
            return HourLayout(route: CGRect(x: 120, y: 90, width: 840, height: 550), eyebrow: 760, hero: 950, heroSize: 190, body: 1030, place: 1092, stroke: 15,
                              lowSun: (880, 700, 62), highSun: (1000, 62, 56))
        case .square:
            return HourLayout(route: CGRect(x: 140, y: 70, width: 800, height: 400), eyebrow: 575, hero: 742, heroSize: 170, body: 814, place: 870, stroke: 14,
                              lowSun: (900, 522, 48), highSun: (1004, 56, 48))
        default:
            return HourLayout(route: CGRect(x: 120, y: 220, width: 840, height: 840), eyebrow: 1330, hero: 1530, heroSize: 214, body: 1616, place: 1680, stroke: 16,
                              lowSun: (880, 1195, 96), highSun: (880, 118, 58))
        }
    }

    func drawHour(_ content: TemplateContent) {
        let palette = HourPalette.of(content.light)
        let layout = hourLayout
        skyGradient(palette.sky)
        sun(content.light, palette: palette, layout: layout)
        fadeToward(palette.scrim, fromY: designHeight * 0.5, bottomAlpha: 220 / 255)
        // Opaque on purpose: a translucent line picks up extra coverage where the stroke's joins
        // overlap and shows it as brighter beads along the route.
        if let geometry = project(content, into: box(layout.route)) {
            route(geometry.runs, joins: geometry.joins, intensities: nil, stroke: layout.stroke,
                  colorAt: { _ in palette.route }, groundAt: { self.skyAt(palette.sky, $0) })
        }
        text(content.lightLine, x: 120, baseline: layout.eyebrow, font: font(34, weight: 600), color: palette.eyebrow, tracking: 0.16, maxWidth: 840)
        hero(content.heroValue, unit: content.heroUnit, x: 120, baseline: layout.hero, size: layout.heroSize, color: palette.hero, unitColor: palette.unit, maxWidth: 840)
        text(content.figures.map(\.value).joined(separator: "  ·  "), x: 120, baseline: layout.body, font: font(44, weight: 500, tabular: true), color: palette.body, maxWidth: 840)
        text(content.placeLine, x: 120, baseline: layout.place, font: font(36, weight: 500), color: palette.body.withAlphaComponent(215 / 255), maxWidth: 840)
        link(content.link)
    }

    /// The light source, placed where it can never sit under a figure.
    private func sun(_ phase: LightPhase, palette: HourPalette, layout: HourLayout) {
        let high = phase == .day || phase == .night
        let spot = high ? layout.highSun : layout.lowSun
        let alpha: CGFloat = phase == .night ? 90 : phase == .day ? 120 : 150
        let center = CGPoint(x: px(spot.0), y: px(spot.1))
        let radius = px(phase == .night ? spot.2 * 0.7 : spot.2)
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [palette.sun.withAlphaComponent(alpha / 2 / 255).cgColor, palette.sun.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: nil) {
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * 2.6, options: [])
        }
        context.setFillColor(palette.sun.withAlphaComponent(alpha / 255).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
