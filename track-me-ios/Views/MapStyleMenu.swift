import SwiftUI
import MapKit

/// The map-style choices shared by the Home and Ride Detail map controls.
///
/// Keeping the selection model with the menu means both screens expose the same localized labels
/// and VoiceOver selected state instead of maintaining two independent copies that can drift.
enum TrackMeMapStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var mapKitStyle: MapKit.MapStyle {
        switch self {
        case .standard: return .standard
        case .satellite: return .imagery
        case .hybrid: return .hybrid
        }
    }

    var localizationKey: String {
        switch self {
        case .standard: return "Normal"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }
}

/// A localized map-style menu with a checkmark and selected accessibility trait on the active row.
struct MapStyleMenu<LabelContent: View>: View {
    @Binding private var selection: TrackMeMapStyle
    private let label: () -> LabelContent
    @State private var hapticTrigger = 0

    init(
        selection: Binding<TrackMeMapStyle>,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self._selection = selection
        self.label = label
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            label()
        }
        .accessibilityLabel(LocalizationHelper.localized("Map style"))
        .accessibilityValue(LocalizationHelper.localized(selection.localizationKey))
        .sensoryFeedback(.selection, trigger: hapticTrigger)
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(TrackMeMapStyle.allCases) { style in
            menuItem(style)
        }
    }

    @ViewBuilder
    private func menuItem(_ style: TrackMeMapStyle) -> some View {
        Button {
            selection = style
            hapticTrigger += 1
        } label: {
            Label {
                Text(LocalizationHelper.localized(style.localizationKey))
            } icon: {
                if selection == style {
                    Image(systemName: "checkmark")
                }
            }
        }
        .accessibilityAddTraits(selection == style ? .isSelected : [])
    }
}
