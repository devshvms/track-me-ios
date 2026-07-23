import SwiftUI

/// TrackMe Brand System v1 — iOS token layer (C2). Target-shared: this file is a
/// member of BOTH the app and the `TrackMeWidgets` extension so the Live Activity
/// stays on-brand.
///
/// Discipline (mirrors Android C1, commit 944b038, and BRAND_SYSTEM.md):
/// brand-action controls bind to CYAN (`primary` / `primaryFill`). Green is NEVER
/// brand — it means "active / running / success" only. Red = SOS/destructive,
/// amber = warning. Semantic roles are strictly decoupled from the brand action
/// token so a "go/success" green can never masquerade as a primary CTA (the bug
/// that shipped a green Start button in 1.5.x while every store asset was cyan).
///
/// Colors are built with a dynamic `UIColor` provider (Any/Dark variants) so they
/// resolve correctly in light/dark and render in WidgetKit — no asset-catalog
/// target-membership juggling required.
enum BrandColor {
    // MARK: Raw palette (BRAND_SYSTEM.md core tokens)
    static let cyanBright = Color(hex: 0x29B6F6) // AA on navy; accents on dark surfaces
    static let cyanDeep = Color(hex: 0x0277B6)   // AA on white (~5:1); interactive cyan
    static let navy900 = Color(hex: 0x12161C)
    static let navy800 = Color(hex: 0x181A20)
    static let navy700 = Color(hex: 0x23272F)
    static let greenGo = Color(hex: 0x16A34A)
    static let redSos = Color(hex: 0xDC2626)
    static let amberWarn = Color(hex: 0xF59E0B)

    // MARK: Semantic roles ---------------------------------------------------

    /// Primary brand accent. Adapts to the surface: `cyanDeep` on light,
    /// `cyanBright` on dark. Use for tints, selected states, accent icons, links.
    static let primary = dynamic(light: 0x0277B6, dark: 0x29B6F6)

    /// Fill for filled brand buttons. Constant `cyanDeep` regardless of mode so a
    /// filled control paired with `onPrimary` is always AA in both light and dark
    /// (a filled button is its own surface, not "cyan on dark").
    static let primaryFill = cyanDeep

    /// Foreground for content on `primaryFill`. White is AA (~5:1) on cyanDeep.
    static let onPrimary = Color.white

    /// Semantic success / active-running (live share broadcasting, ride active,
    /// export complete). NOT a call-to-action. Never the primary button.
    static let success = greenGo
    /// Dark success container tint (e.g. the offline-shield "active" banner).
    static let successContainerDark = Color(hex: 0x14532D)
    /// Foreground for content on `warning` (amber). Navy is AA on amber; white is not.
    static let onWarning = navy900

    /// SOS / destructive / error.
    static let sos = redSos
    /// A deeper SOS red for the fully-armed slider state.
    static let sosDeep = Color(hex: 0xB30000)

    /// Warning (GPS lost, paused, pending/processing).
    static let warning = amberWarn

    // MARK: Data-visualization series (data encoding, not brand or state)
    static let chartSpeed = greenGo
    static let chartAltitude = amberWarn

    // MARK: Helpers ----------------------------------------------------------

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

/// UIColor variants for UIKit/CoreGraphics contexts (e.g. `ImageExporter` route
/// rendering) where a SwiftUI `Color` cannot be used directly.
enum BrandUIColor {
    static let primary = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(rgb: 0x29B6F6) : UIColor(rgb: 0x0277B6)
    }
    static let cyanBright = UIColor(rgb: 0x29B6F6)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
