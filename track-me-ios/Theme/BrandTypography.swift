import SwiftUI

/// TrackMe Brand System v1 — Inter typography (C2).
///
/// Inter is the single UI family (BRAND_SYSTEM.md). Fonts are built with
/// `relativeTo:` a system text style so Dynamic Type continues to scale them —
/// `Font.custom(_:size:)` alone would pin a fixed size and break accessibility
/// text sizes. If the bundled font fails to register (renamed PostScript name,
/// missing resource), `Font.custom` falls back to the system font automatically,
/// so text is always readable.
///
/// Data-dense readouts (durations, coordinates, speeds) deliberately keep a
/// monospaced-digit system font where column alignment matters more than family.
enum BrandTypography {
    static let familyName = "Inter"

    static func inter(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font.custom(familyName, size: size, relativeTo: style).weight(weight)
    }

    // Role fonts (sizes track the iOS type scale; Inter 400/500/600/700).
    static var largeTitle: Font { inter(34, relativeTo: .largeTitle, weight: .bold) }
    static var title: Font { inter(28, relativeTo: .title, weight: .bold) }
    static var title2: Font { inter(22, relativeTo: .title2, weight: .semibold) }
    static var title3: Font { inter(20, relativeTo: .title3, weight: .semibold) }
    static var headline: Font { inter(17, relativeTo: .headline, weight: .semibold) }
    static var body: Font { inter(17, relativeTo: .body, weight: .regular) }
    static var callout: Font { inter(16, relativeTo: .callout, weight: .regular) }
    static var subheadline: Font { inter(15, relativeTo: .subheadline, weight: .regular) }
    static var footnote: Font { inter(13, relativeTo: .footnote, weight: .regular) }
    static var caption: Font { inter(12, relativeTo: .caption, weight: .regular) }
}

extension View {
    /// Apply Inter as the default font for this subtree. Individual `Text`s can
    /// still override. Applied once at the app root so the whole UI defaults to
    /// Inter without touching every view (token-level migration, not a redesign).
    func brandDefaultFont() -> some View {
        self.font(BrandTypography.body)
    }
}
