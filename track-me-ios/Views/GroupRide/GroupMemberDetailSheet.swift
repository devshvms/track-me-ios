import SwiftUI
import UIKit

struct GroupMemberDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let member: GroupWire.MemberPosition
    let name: String
    let status: RiderStatus?
    let age: StatusAge.Bucket
    let isFresh: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        LocalizationHelper.localized("Last known point"),
                        value: GroupAgePresentation.text(age) ?? LocalizationHelper.localized("Age unavailable")
                    )
                    if let status {
                        LabeledContent {
                            Label(
                                RiderStatusPresentation.label(for: status),
                                systemImage: RiderStatusPresentation.systemImage(status.severity)
                            )
                            .foregroundStyle(
                                isFresh
                                    ? RiderStatusPresentation.textColor(status.severity)
                                    : Color.secondary
                            )
                        } label: {
                            Text(LocalizationHelper.localized("Status"))
                        }
                    }
                }

                Section(LocalizationHelper.localized("Directions to last known point")) {
                    Button {
                        open(.apple)
                    } label: {
                        Label(providerLabel("Apple Maps"), systemImage: "map")
                            .foregroundStyle(isFresh ? BrandColor.primary : Color.secondary)
                            .saturation(isFresh ? 1 : 0)
                    }
                    if GroupDirectionsProvider.google.isAvailable {
                        Button {
                            open(.google)
                        } label: {
                            Label(providerLabel("Google Maps"), systemImage: "map.fill")
                                .foregroundStyle(isFresh ? BrandColor.primary : Color.secondary)
                                .saturation(isFresh ? 1 : 0)
                        }
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationHelper.localized("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func providerLabel(_ key: String) -> String {
        guard let age = GroupAgePresentation.text(age) else {
            return LocalizationHelper.localized(key)
        }
        return "\(LocalizationHelper.localized(key)) · \(age)"
    }

    private func open(_ provider: GroupDirectionsProvider) {
        guard let url = provider.url(lat: member.lat, lng: member.lng) else {
            ToastManager.shared.show(message: LocalizationHelper.localized("No maps app is available."), style: .warning)
            return
        }
        let ageBucket = GroupAgePresentation.telemetryBucket(age)
        UIApplication.shared.open(url) { opened in
            if opened {
                TelemetryManager.shared.trackGroupDirectionsOpened(ageBucket: ageBucket)
            } else {
                ToastManager.shared.show(message: LocalizationHelper.localized("No maps app is available."), style: .warning)
            }
        }
    }
}
