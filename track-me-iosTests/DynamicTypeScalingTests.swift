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
        // Recorded from the pre-change .large HUD card at a 320pt content width.
        // The tracking state includes TIME plus the SPEED/DISTANCE row.
        XCTAssertEqual(height(card(.large), width: cardWidth), 284.33, accuracy: 1)
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

    func testLiveShareTimerGrowsWithDynamicType() {
        XCTAssertGreaterThan(
            height(LiveShareRemainingTimeView(text: "12:34").environment(\.dynamicTypeSize, .accessibility1)),
            height(LiveShareRemainingTimeView(text: "12:34").environment(\.dynamicTypeSize, .large))
        )
    }
}
