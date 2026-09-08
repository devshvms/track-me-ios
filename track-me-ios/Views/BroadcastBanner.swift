import SwiftUI

/// SCOPE_1.8.7 §6.3 — the in-app half of an operator broadcast.
///
/// shvm's decision was two surfaces per broadcast, and this is the one that survives: a
/// notification is something you swipe away at a traffic light, so if the banner were the only
/// place a broadcast lived, "we told everyone" would mean "we told everyone who happened to be
/// looking".
///
/// Deliberately **not** a sheet or an alert. A modal over the first screen someone opens is the
/// shape of an ad, and using that shape for an operational notice would spend exactly the goodwill
/// that makes the operational notice work.
///
/// Dismissal is per-broadcast and permanent — `markSeen` — because a message the user has read and
/// understood should not follow them around. The push already interrupted once; this is the record,
/// not a second interruption.
struct BroadcastBanner: View {
    let broadcast: OperatorBroadcast
    let onDismiss: () -> Void

    /// Urgent is the only tag that earns the destructive colour. Painting a maintenance notice red
    /// would make every broadcast look like an emergency, which is how a channel stops being read.
    private var accent: Color {
        broadcast.tag == .urgent ? BrandColor.destructive : BrandColor.primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(broadcast.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(accent)
            Text(broadcast.body)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let link = broadcast.learnMoreUrl, let url = URL(string: link) {
                    // The parser has already refused anything that is not https, so this cannot
                    // open a scheme the operator did not intend. The check lives at the boundary
                    // rather than here, where it would be easy to forget on the next surface.
                    Link(LocalizationHelper.localized("Learn more"), destination: url)
                        .font(.footnote.weight(.medium))
                }
                Spacer()
                Button(LocalizationHelper.localized("Got it"), action: onDismiss)
                    .font(.footnote.weight(.medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
