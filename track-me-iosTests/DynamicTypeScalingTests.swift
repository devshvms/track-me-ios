import XCTest
import SwiftUI
import UIKit
@testable import track_me_ios

@MainActor
final class DynamicTypeScalingTests: XCTestCase {
    private let cardWidth: CGFloat = 320

    private func statReadout(_ size: DynamicTypeSize) -> some View {
        RideStatReadout(
            label: "Speed",
            value: "12.3",
            unit: "km/h",
            accessibilityValue: "12.3 km/h"
        )
        .environment(\.dynamicTypeSize, size)
    }

    private func height<V: View>(_ view: V, width: CGFloat = 320) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func card(_ size: DynamicTypeSize) -> some View {
        RideStatsCard(
            isTracking: true,
            duration: "12:34",
            speedValue: "12.3",
            speedUnit: "km/h",
            speedAccessibilityValue: "12.3 km/h",
            distanceValue: "4.56",
            distanceUnit: "km",
            distanceAccessibilityValue: "4.56 km"
        )
        .environment(\.dynamicTypeSize, size)
    }

    func testHudStatsReadoutGrowsWithDynamicType() {
        XCTAssertGreaterThan(
            height(statReadout(.accessibility1)),
            height(statReadout(.large)),
            "HUD readout must scale with Dynamic Type — a pinned .system(size:) would make these equal"
        )
    }

    func testHudStatsCardHonorsAccessibilityClamp() {
        let large = height(card(.large), width: cardWidth)
        let accessibility3 = height(card(.accessibility3), width: cardWidth)
        let accessibility5 = height(card(.accessibility5), width: cardWidth)

        XCTAssertGreaterThan(accessibility3, large)
        XCTAssertEqual(accessibility3, accessibility5, accuracy: 1)
    }

    func testHudStatsCardDefaultHeightRemainsStable() {
        let compactHeight = height(card(.large), width: cardWidth)
        XCTAssertGreaterThan(compactHeight, 60)
        XCTAssertLessThan(compactHeight, 140, "The active HUD should preserve the map-first layout")
    }

    func testRideStatReadoutProvidesOneAccessibleElement() {
        let readout = RideStatReadout(
            label: "Speed",
            value: "12.3",
            unit: "km/h",
            accessibilityValue: "12.3 km/h"
        )

        XCTAssertEqual(
            readout.accessibilityDescriptor,
            RideStatAccessibilityDescriptor(label: "Speed", value: "12.3 km/h")
        )
    }

}
