import CoreGraphics
import CoreLocation
import UIKit

/// Draws a single replay frame. The map projection is supplied by MapKit and is
/// intentionally never re-derived here; when it is unavailable we render a
/// plain navy background with a truthful, simple route fallback.
enum ReplayFrameRenderer {
    private static let navy = UIColor(rgb: 0x12161C)
    private static let scrim = UIColor(red: 18 / 255, green: 22 / 255, blue: 28 / 255, alpha: 92 / 255)

    static func render(
        context: CGContext,
        points: [GPSPoint],
        progress: Double,
        persona: RidePersona,
        stats: ReplayStats,
        config: ReplayExportConfig,
        mapSnapshot: UIImage?,
        routeProjection: [(CGFloat, CGFloat)]?
    ) {
        let width = CGFloat(config.width)
        let height = CGFloat(config.height)
        context.setFillColor(navy.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let projectionValid = mapSnapshot != nil && routeProjection?.count == points.count
        var mapRect: CGRect?
        if projectionValid, let image = mapSnapshot {
            let scale = max(width / image.size.width, height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(x: (width - size.width) / 2, y: (height - size.height) / 2,
                             width: size.width, height: size.height)
            image.draw(in: rect)
            context.setFillColor(scrim.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            mapRect = rect
        }

        let route = routePoints(points, projection: projectionValid ? routeProjection : nil,
                                canvas: CGSize(width: width, height: height), mapRect: mapRect)
        guard !route.isEmpty else { return drawChrome(context: context, persona: persona, stats: stats, config: config, size: CGSize(width: width, height: height)) }

        context.setStrokeColor(BrandUIColor.cyanBright.cgColor)
        context.setLineWidth(max(5, width * 0.006))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: route[0])
        for point in route.dropFirst() { context.addLine(to: point) }
        context.strokePath()

        drawPin(context, at: route[0], start: true)
        drawPin(context, at: route[route.count - 1], start: false)
        let clamped = min(1, max(0, progress))
        let scaled = clamped * Double(route.count - 1)
        let index = min(route.count - 1, Int(scaled))
        let local = CGFloat(scaled - Double(index))
        let current = route[index]
        let next = route[min(route.count - 1, index + 1)]
        let marker = CGPoint(x: current.x + (next.x - current.x) * local,
                             y: current.y + (next.y - current.y) * local)
        drawMarker(context, at: marker, heading: atan2(next.y - current.y, next.x - current.x))
        drawChrome(context: context, persona: persona, stats: stats, config: config, size: CGSize(width: width, height: height))
    }

    private static func routePoints(_ points: [GPSPoint], projection: [(CGFloat, CGFloat)]?, canvas: CGSize, mapRect: CGRect?) -> [CGPoint] {
        if let projection, projection.count == points.count, let rect = mapRect {
            return projection.map { CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height) }
        }
        guard !points.isEmpty else { return [] }
        let minLat = points.map(\.latitude).min() ?? 0
        let maxLat = points.map(\.latitude).max() ?? minLat
        let minLon = points.map(\.longitude).min() ?? 0
        let maxLon = points.map(\.longitude).max() ?? minLon
        let spanLat = max(0.000001, maxLat - minLat)
        let spanLon = max(0.000001, maxLon - minLon)
        let inset = min(canvas.width, canvas.height) * 0.16
        return points.map { point in
            CGPoint(x: inset + CGFloat((point.longitude - minLon) / spanLon) * (canvas.width - 2 * inset),
                    y: canvas.height - inset - CGFloat((point.latitude - minLat) / spanLat) * (canvas.height - 2 * inset))
        }
    }

    private static func drawPin(_ context: CGContext, at point: CGPoint, start: Bool) {
        context.setFillColor((start ? UIColor(rgb: 0x16A34A) : BrandUIColor.cyanBright).cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(3)
        context.addEllipse(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
        context.fillPath()
        if !start {
            context.addEllipse(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
            context.strokePath()
        }
    }

    private static func drawMarker(_ context: CGContext, at point: CGPoint, heading: CGFloat) {
        context.setFillColor(UIColor.white.cgColor)
        context.addEllipse(in: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        context.fillPath()
        context.saveGState(); context.translateBy(x: point.x, y: point.y); context.rotate(by: heading)
        context.setFillColor(BrandUIColor.cyanBright.cgColor)
        context.move(to: CGPoint(x: 15, y: 0)); context.addLine(to: CGPoint(x: -8, y: -7)); context.addLine(to: CGPoint(x: -8, y: 7)); context.closePath(); context.fillPath()
        context.restoreGState()
    }

    private static func drawChrome(context: CGContext, persona: RidePersona, stats: ReplayStats, config: ReplayExportConfig, size: CGSize) {
        let overlay = config.overlay
        let ink: UIColor = overlay.darkTheme ? .white : UIColor(white: 0.07, alpha: 1)

        // The link is not chrome the user opted into — it is what makes the artifact traceable
        // back to the app, so it is drawn whatever the figure toggles say. The pill that used to
        // carry an icon and a "TrackMe" wordmark above it is gone: a shared video of someone's ride
        // is theirs, and a branded plate in the corner is the app inserting itself into it. The
        // link alone does the job the pill was justified by.
        //
        // Bottom-right, matching the Android renderer and the still exporter. The map's own Google
        // attribution runs along the bottom-left and must not be crowded.
        if let link = config.deepLink, ReplayDeepLink.isTrackMeLink(link) {
            let inset = min(size.width, size.height) * 0.022
            let linkHeight: CGFloat = 20
            drawText(
                link,
                in: CGRect(
                    x: size.width * 0.35,
                    y: size.height - inset - linkHeight,
                    width: size.width * 0.65 - inset,
                    height: linkHeight
                ),
                // Roughly half the old wordmark, and the same ratio against the shorter edge that
                // the Android renderer uses, so a video exported on either phone reads the same.
                font: .systemFont(ofSize: max(9, min(size.width, size.height) * 0.014)),
                color: ink.withAlphaComponent(0.82),
                context: context,
                alignment: .right
            )
        }

        // TASK-305: the figures come from the preview, already formatted, rather than being
        // re-derived here. The old code called `UnitFormatter.distance` and
        // `HistoryMetricFormat.duration` itself and ignored the three toggles entirely — so the
        // video showed figures the user had switched off, and showed the duration as `00:17:00`
        // where the image showed `17min`.
        guard overlay.drawsPanel else { return }

        let label = overlay.personaLabel ?? persona.displayName
        drawText(
            label,
            in: CGRect(x: 32, y: 30, width: size.width * 0.65, height: 40),
            font: .boldSystemFont(ofSize: max(22, size.width * 0.035)),
            color: ink,
            context: context
        )
        drawText(
            overlay.figures.joined(separator: ExportOverlayContent.separator),
            in: CGRect(x: 32, y: size.height - 76, width: size.width - 64, height: 42),
            font: .systemFont(ofSize: max(18, size.width * 0.027), weight: .semibold),
            color: ink,
            context: context
        )

    }

    private static func drawText(_ value: String, in rect: CGRect, font: UIFont, color: UIColor, context: CGContext, alignment: NSTextAlignment = .left) {
        UIGraphicsPushContext(context)
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = alignment; return p }()])
        UIGraphicsPopContext()
    }
}
