import SwiftUI

/// TASK-276 / LEVEL-THEME-01: one accent per level, so the ladder reads as a progression rather
/// than six identical dots.
///
/// Values match Android's exactly. Two constraints fixed them, and both came out of review rather
/// than taste.
///
/// **Level 1 is the colour the app ships today.** That is shvm's stated intent, and the palette the
/// radial version carried had it wrong: slate at level 1 and `#0277B6` at level 2, where `#0277B6`
/// *is* `BrandColor.cyanDeep`. Every existing rider would have been demoted to grey on upgrade.
///
/// **The ladder stays out of the reserved semantic registers.** `BRAND_SYSTEM.md` pins green to
/// active/success, red to SOS/error and amber to warning, and the earlier palette put levels 4 and 5
/// in amber and level 3 dark in teal. On a screen whose whole job is locked-versus-unlocked, an
/// amber accent reads as caution. Cyan → blue → indigo → violet → magenta deepens visibly without
/// ever borrowing a colour that means something else in this app.
///
/// Still a proposal: Product/CX owns the final hues, and this is what the ladder looks like if they
/// approve the shape rather than a description of it.
enum GamificationPalette {

    private static let light: [Color] = [
        Color(hex: 0x0277B6), // Starter — BrandColor.cyanDeep, the app as it ships
        Color(hex: 0x1D63C4),
        Color(hex: 0x4B4FD1),
        Color(hex: 0x7139C9),
        Color(hex: 0x9B2FB4),
        Color(hex: 0xB32079),
    ]

    private static let dark: [Color] = [
        Color(hex: 0x29B6F6), // Starter — BrandColor.cyanBright, the dark-theme brand accent
        Color(hex: 0x5AA9FF),
        Color(hex: 0x8A9CFF),
        Color(hex: 0xB18BFF),
        Color(hex: 0xD583F0),
        Color(hex: 0xF27BC0),
    ]

    /// Accent for a level index, clamped so an unexpected index cannot trap on a rendering path.
    static func accent(_ levelIndex: Int, dark isDark: Bool) -> Color {
        let palette = isDark ? dark : light
        return palette[min(max(levelIndex, 0), palette.count - 1)]
    }

    /// Readable ink on `accent`. Every hue above is dark enough in light theme to take white.
    static func onAccent(dark isDark: Bool) -> Color {
        isDark ? Color(hex: 0x12161C) : .white
    }
}
