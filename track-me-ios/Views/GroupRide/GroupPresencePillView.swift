import SwiftUI

struct GroupPresencePillView: View {
    let pill: GroupPresencePolicy.Pill
    let onOpenCommunity: () -> Void
    let onClearStatus: () -> Void

    var body: some View {
        if let presentation {
            HStack(spacing: 8) {
                Button(action: onOpenCommunity) {
                    HStack(spacing: 8) {
                        Image(systemName: presentation.systemImage)
                        Text(presentation.text)
                            .font(.caption.bold())
                            .multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if presentation.canClear {
                    Button(action: onClearStatus) {
                        Image(systemName: "xmark")
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizationHelper.localized("Clear status"))
                }
            }
            .foregroundStyle(presentation.foreground)
            .padding(.leading, 14)
            .padding(.trailing, presentation.canClear ? 2 : 14)
            .frame(minHeight: 44)
            .background(presentation.background.opacity(0.96), in: Capsule())
            .overlay(Capsule().stroke(presentation.background, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var presentation: Presentation? {
        switch pill {
        case .none:
            return nil
        case .statusReminder(let status, let age):
            return Presentation(
                text: statusText(status, suffix: GroupAgePresentation.text(age, includesAgo: false)),
                systemImage: RiderStatusPresentation.systemImage(status.severity),
                background: RiderStatusPresentation.color(status.severity),
                foreground: RiderStatusPresentation.fillForeground(status.severity),
                canClear: status.severity != .alert
            )
        case .statusUnsent(let status):
            return Presentation(
                text: statusText(status, suffix: LocalizationHelper.localized("Not sent yet")),
                systemImage: RiderStatusPresentation.systemImage(status.severity),
                background: RiderStatusPresentation.color(status.severity).opacity(0.72),
                foreground: RiderStatusPresentation.fillForeground(status.severity),
                canClear: false
            )
        case .clearing(let status):
            return Presentation(
                text: statusText(status, suffix: LocalizationHelper.localized("Clearing…")),
                systemImage: "clock.arrow.circlepath",
                background: RiderStatusPresentation.color(status.severity),
                foreground: RiderStatusPresentation.fillForeground(status.severity),
                canClear: false
            )
        case .paused(let cause, let rideRecording, let lastShared):
            let shared = GroupAgePresentation.text(lastShared)
                .map { LocalizationHelper.formatted("Last shared %@", $0) }
            let clauses: [String]
            switch cause {
            case .local:
                clauses = ([
                    rideRecording ? LocalizationHelper.localized("Ride recording on this phone") : nil,
                    LocalizationHelper.localized("Group updates paused"),
                    shared
                ] as [String?]).compactMap { $0 }
            case .relay:
                clauses = [LocalizationHelper.localized("Group sharing unavailable · retrying")]
            }
            return Presentation(
                text: clauses.joined(separator: " · "),
                systemImage: "wifi.exclamationmark",
                background: BrandColor.warning,
                foreground: BrandColor.onWarning,
                canClear: false
            )
        case .pausedWithPendingStatus(let cause, let rideRecording, let status, let isClearing):
            let groupState = cause == .local
                ? LocalizationHelper.localized("Group updates paused")
                : LocalizationHelper.localized("Group sharing unavailable · retrying")
            let consequence = isClearing
                ? "\(RiderStatusPresentation.label(for: status)) · \(LocalizationHelper.localized("Clearing…"))"
                : "\(RiderStatusPresentation.label(for: status)) \(LocalizationHelper.localized("not sent"))"
            let clauses: [String?] = [
                rideRecording ? LocalizationHelper.localized("Ride recording on this phone") : nil,
                groupState,
                consequence
            ]
            return Presentation(
                text: clauses.compactMap { $0 }.joined(separator: " · "),
                systemImage: RiderStatusPresentation.systemImage(status.severity),
                background: status.isAlert ? BrandColor.severityAlert : BrandColor.warning,
                foreground: status.isAlert ? .white : BrandColor.onWarning,
                canClear: false
            )
        case .notSharing(let status, let acknowledged, let isClearing):
            var text = LocalizationHelper.localized("You're not sharing your location. Others can't see you.")
            if let status {
                let delivery = isClearing
                    ? LocalizationHelper.localized("Clearing…")
                    : LocalizationHelper.localized(acknowledged ? "sent" : "not sent")
                text = LocalizationHelper.formatted(
                    "You're not sharing your location · %@ %@",
                    RiderStatusPresentation.label(for: status),
                    delivery
                )
            }
            return Presentation(
                text: text,
                systemImage: "location.slash.fill",
                background: BrandColor.severityAlert,
                foreground: .white,
                canClear: false
            )
        }
    }

    private func statusText(_ status: RiderStatus, suffix: String?) -> String {
        let label = RiderStatusPresentation.label(for: status)
        return suffix.map { "\(label) · \($0)" } ?? label
    }

    private struct Presentation {
        let text: String
        let systemImage: String
        let background: Color
        let foreground: Color
        let canClear: Bool
    }
}
