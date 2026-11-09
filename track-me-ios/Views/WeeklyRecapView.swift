import SwiftUI

/// B2 weekly recap card (iOS) with the B3 streak line. Parity with Android's WeeklyRecapDialog.
/// STRICTLY gain-framed: only appears when there is something to celebrate (rides > 0) and never
/// shows a loss/at-risk/comparison message. Accent-tinted (C2 repoints to cyan); Dynamic Type +
/// VoiceOver friendly. Telemetry is emitted once per week by the coordinator.
struct WeeklyRecapView: View {
    let recap: WeeklyRecap
    let onDismiss: () -> Void
    @ObservedObject private var unitSettings = UnitSettings.shared
    @State private var shareItems: [Any] = []
    @State private var isShowingShareSheet = false

    var body: some View {
        VStack(spacing: 20) {
            Text(LocalizationHelper.localized("Your week in review"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 32)

            VStack(spacing: 12) {
                statRow(LocalizationHelper.localized("Rides"), "\(recap.rideCount)")
                statRow(LocalizationHelper.localized("Distance"),
                        UnitFormatter.distance(meters: recap.distanceMeters, unit: unitSettings.unit, decimals: 1))
            }
            .padding(.horizontal, 28)

            if let streak = streakLine {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(streak).font(.body.weight(.medium))
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(streak)
            }

            Spacer(minLength: 0)

            Button {
                let cardImage = Self.renderRecapCard(recap: recap, unit: unitSettings.unit, streakLine: streakLine)
                shareItems = [cardImage, shareText]
                isShowingShareSheet = true
            } label: {
                Label(LocalizationHelper.localized("Share Recap Card"), systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)

            Button(action: onDismiss) {
                Text(LocalizationHelper.localized("Nice week!"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(
                activityItems: shareItems,
                onActivityCompletion: { activityType, completed, _ in
                    guard completed else { return }
                    let channel = TelemetryManager.resolveShareChannel(activityType?.rawValue)
                    TelemetryManager.shared.trackRecapShared(
                        weekKey: recap.weekKey,
                        rideCount: recap.rideCount,
                        distanceKm: recap.distanceMeters / 1000.0
                    )
                    TelemetryManager.shared.trackRouteCardShared(
                        template: "weekly_recap",
                        channel: channel
                    )
                }
            )
        }
    }

    private var streakLine: String? {
        if recap.streakWeeks >= 2 {
            return LocalizationHelper.formatted("%lld weeks active in a row", recap.streakWeeks)
        } else if recap.streakWeeks == 1 {
            return LocalizationHelper.localized("You stayed active this week")
        }
        return nil
    }

    private var shareText: String {
        let dist = UnitFormatter.distance(meters: recap.distanceMeters, unit: unitSettings.unit, decimals: 1)
        var text = "🚴 TrackMe Weekly Recap (\(recap.weekKey))\n• \(LocalizationHelper.localized("Distance")): \(dist)\n• \(LocalizationHelper.localized("Rides")): \(recap.rideCount)"
        if let streak = streakLine {
            text += "\n• \(streak)"
        }
        text += "\nhttps://trackme.shvms.in/get?utm_source=weekly_recap&utm_medium=share"
        return text
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.title3.weight(.semibold))
        }
    }

    /// TASK-358: Renders a 1080x1080 branded social recap card matching Android's WeeklyRecapCardRenderer.
    static func renderRecapCard(recap: WeeklyRecap, unit: DistanceUnit, streakLine: String?) -> UIImage {
        let size = CGSize(width: 1080, height: 1080)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            // Deep charcoal background (#111318)
            UIColor(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0, alpha: 1.0).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Inner card container (margin 48px, rounded 36px)
            let margin: CGFloat = 48
            let cardRect = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 36)
            cg.saveGState()
            cardPath.addClip()
            let colors = [
                UIColor(red: 0x21 / 255.0, green: 0x25 / 255.0, blue: 0x2D / 255.0, alpha: 1.0).cgColor,
                UIColor(red: 0x17 / 255.0, green: 0x1A / 255.0, blue: 0x20 / 255.0, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: margin, y: margin),
                    end: CGPoint(x: margin, y: size.height - margin),
                    options: []
                )
            }
            cg.restoreGState()

            UIColor(white: 1.0, alpha: 40.0 / 255.0).setStroke()
            cardPath.lineWidth = 2
            cardPath.stroke()

            // Emerald active dot (#00E676) + TRACKME header
            UIColor(red: 0x00 / 255.0, green: 0xE6 / 255.0, blue: 0x76 / 255.0, alpha: 1.0).setFill()
            UIBezierPath(arcCenter: CGPoint(x: margin + 44, y: margin + 56), radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

            let brandAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor(red: 0xE1 / 255.0, green: 0xE2 / 255.0, blue: 0xE8 / 255.0, alpha: 1.0),
                .kern: 1.8
            ]
            NSString(string: "TRACKME").draw(at: CGPoint(x: margin + 64, y: margin + 42), withAttributes: brandAttrs)

            // Week key (top right)
            let weekAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor(red: 0x8E / 255.0, green: 0x91 / 255.0, blue: 0x9A / 255.0, alpha: 1.0)
            ]
            let weekStr = NSString(string: recap.weekKey)
            let weekSize = weekStr.size(withAttributes: weekAttrs)
            weekStr.draw(at: CGPoint(x: size.width - margin - 44 - weekSize.width, y: margin + 44), withAttributes: weekAttrs)

            // Subhead
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor(red: 0x9C / 255.0, green: 0xA3 / 255.0, blue: 0xAF / 255.0, alpha: 1.0),
                .kern: 2.8
            ]
            NSString(string: LocalizationHelper.localized("Your week in review").uppercased())
                .draw(at: CGPoint(x: margin + 44, y: margin + 114), withAttributes: titleAttrs)

            // Hero distance
            let distStr = UnitFormatter.distance(meters: recap.distanceMeters, unit: unit, decimals: 1)
            let heroAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 92, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            NSString(string: distStr).draw(at: CGPoint(x: margin + 44, y: margin + 160), withAttributes: heroAttrs)

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .regular),
                .foregroundColor: UIColor(red: 0x8E / 255.0, green: 0x91 / 255.0, blue: 0x9A / 255.0, alpha: 1.0)
            ]
            NSString(string: LocalizationHelper.localized("Distance").uppercased())
                .draw(at: CGPoint(x: margin + 44, y: margin + 272), withAttributes: labelAttrs)

            // Divider
            UIColor(white: 1.0, alpha: 30.0 / 255.0).setStroke()
            let divider = UIBezierPath()
            divider.move(to: CGPoint(x: margin + 44, y: margin + 340))
            divider.addLine(to: CGPoint(x: size.width - margin - 44, y: margin + 340))
            divider.lineWidth = 2
            divider.stroke()

            // Rides & Streak Grid
            let statValAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let statLblAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor(red: 0x8E / 255.0, green: 0x91 / 255.0, blue: 0x9A / 255.0, alpha: 1.0)
            ]
            NSString(string: "\(recap.rideCount)").draw(at: CGPoint(x: margin + 44, y: margin + 374), withAttributes: statValAttrs)
            NSString(string: LocalizationHelper.localized("Rides").uppercased())
                .draw(at: CGPoint(x: margin + 44, y: margin + 448), withAttributes: statLblAttrs)

            let streakVal = recap.streakWeeks >= 2 ? "\(recap.streakWeeks)" : (recap.streakWeeks == 1 ? "1" : "—")
            let streakLbl = (streakLine ?? LocalizationHelper.localized("You stayed active this week")).uppercased()
            NSString(string: streakVal).draw(at: CGPoint(x: margin + 440, y: margin + 374), withAttributes: statValAttrs)
            NSString(string: streakLbl).draw(at: CGPoint(x: margin + 440, y: margin + 448), withAttributes: statLblAttrs)

            // Footer tagline & corner attribution link
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor(red: 0x6B / 255.0, green: 0x72 / 255.0, blue: 0x80 / 255.0, alpha: 1.0)
            ]
            NSString(string: "TrackMe • Privacy-first GPS tracker")
                .draw(at: CGPoint(x: margin + 44, y: size.height - margin - 72), withAttributes: footerAttrs)

            let linkAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor(white: 235.0 / 255.0, alpha: 200.0 / 255.0)
            ]
            let linkStr = NSString(string: "trackme.shvms.in/r")
            let linkSize = linkStr.size(withAttributes: linkAttrs)
            linkStr.draw(at: CGPoint(x: size.width - margin - 44 - linkSize.width, y: size.height - margin - 74), withAttributes: linkAttrs)
        }
    }
}
