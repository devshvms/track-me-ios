import XCTest
import SwiftUI
@testable import track_me_ios

/// C2 — brand token validation (iOS parity with Android `ThemeContrastTest`).
/// Confirms the cyan brand tokens resolve to the BRAND_SYSTEM.md hexes in
/// light/dark, that semantic roles are decoupled from the brand-action token,
/// and that on-color pairings meet WCAG AA (4.5:1).
final class BrandColorTests: XCTestCase {

    private func rgb(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func hex(_ color: Color, dark: Bool) -> Int {
        let c = rgb(color, dark: dark)
        return (Int((c.r * 255).rounded()) << 16) | (Int((c.g * 255).rounded()) << 8) | Int((c.b * 255).rounded())
    }

    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = luminance(rgb(a, dark: dark)), lb = luminance(rgb(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: token hexes ------------------------------------------------------

    func testPrimaryAdaptsCyanDeepLightCyanBrightDark() {
        XCTAssertEqual(hex(BrandColor.primary, dark: false), 0x0277B6, "primary is cyanDeep on light")
        XCTAssertEqual(hex(BrandColor.primary, dark: true), 0x29B6F6, "primary is cyanBright on dark")
    }

    func testSemanticTokenHexesMatchBrandSystem() {
        XCTAssertEqual(hex(BrandColor.success, dark: false), 0x16A34A)
        XCTAssertEqual(hex(BrandColor.sos, dark: false), 0xDC2626)
        XCTAssertEqual(hex(BrandColor.warning, dark: false), 0xF59E0B)
    }

    // MARK: semantic decoupling ---------------------------------------------

    func testGreenIsNotTheBrandAction() {
        // The whole point of C2/C1: success-green must never equal the primary
        // brand-action token in either appearance.
        XCTAssertNotEqual(hex(BrandColor.success, dark: false), hex(BrandColor.primary, dark: false))
        XCTAssertNotEqual(hex(BrandColor.success, dark: true), hex(BrandColor.primary, dark: true))
    }

    // MARK: contrast (AA) ----------------------------------------------------

    func testOnPrimaryMeetsAAOnFilledButton() {
        // White label on cyanDeep fill, in both appearances (fill is constant).
        XCTAssertGreaterThanOrEqual(contrast(BrandColor.onPrimary, BrandColor.primaryFill, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(BrandColor.onPrimary, BrandColor.primaryFill, dark: true), 4.5)
    }

    func testOnWarningMeetsAA() {
        // Navy text on amber warning banner.
        XCTAssertGreaterThanOrEqual(contrast(BrandColor.onWarning, BrandColor.warning, dark: false), 4.5)
    }

    func testChartTokensMatchExpectedHuesAndMeetGraphicalContrast() {
        // Chart tokens should be the exact data hues.
        XCTAssertEqual(hex(BrandColor.chartSpeed, dark: false), 0x16A34A)
        XCTAssertEqual(hex(BrandColor.chartAltitude, dark: false), 0xF59E0B)

        // Graphical elements need 3.0:1 on the chart background (we'll assume standard system backgrounds)
        // White/dark surfaces check
        XCTAssertGreaterThanOrEqual(contrast(BrandColor.chartSpeed, .white, dark: false), 3.0)
        XCTAssertGreaterThanOrEqual(contrast(BrandColor.chartAltitude, .black, dark: true), 3.0)
    }
}
