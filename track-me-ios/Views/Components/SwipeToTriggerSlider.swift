import SwiftUI

struct SwipeToTriggerSlider: View {
    var onTriggered: () -> Void
    var text: String = "Swipe for SOS"

    @State private var offset: CGFloat = 0
    @State private var isTriggered: Bool = false
    @State private var countdown: Int = 10
    @State private var timer: Timer?
    @State private var animationProgress: CGFloat = 0
    @State private var lastHapticOffset: CGFloat = 0

    let thumbSize: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            let maxDrag = geometry.size.width - thumbSize

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: thumbSize / 2)
                    .fill(isTriggered ? BrandColor.sos.opacity(0.8) : BrandColor.sos.opacity(0.3))

                if !isTriggered {
                    Text(text)
                        .font(.subheadline).bold()
                        .foregroundColor(BrandColor.sos)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Circle()
                        .fill(BrandColor.sos)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.white)
                        )
                        .offset(x: offset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if value.translation.width > 0 {
                                        offset = min(maxDrag, value.translation.width)
                                        if abs(offset - lastHapticOffset) > 50 {
                                            Haptics.selection()
                                            lastHapticOffset = offset
                                        }
                                    }
                                }
                                .onEnded { value in
                                    if offset > maxDrag * 0.95 {
                                        triggerCountdown()
                                    } else {
                                        withAnimation(.spring()) {
                                            offset = 0
                                        }
                                    }
                                    lastHapticOffset = 0
                                }
                        )
                } else {
                    RoundedRectangle(cornerRadius: thumbSize / 2)
                        .fill(BrandColor.sosDeep)
                        .frame(width: max(thumbSize, geometry.size.width * animationProgress))
                        .animation(.linear(duration: Double(countdown)), value: animationProgress)

                    HStack(alignment: .center) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text(LocalizationHelper.formatted("Cancel (%@)", String(countdown)))
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cancelCountdown()
                    }
                }
            }
            // The physical drag is impossible for VoiceOver users, so expose the
            // whole control as a single button whose activation (double-tap)
            // starts — or, mid-countdown, cancels — the SOS. This is the only
            // path that makes the safety feature operable with VoiceOver on.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction {
                if isTriggered {
                    cancelCountdown()
                } else {
                    triggerCountdown()
                }
            }
            .accessibilityAction(.escape) {
                if isTriggered { cancelCountdown() }
            }
        }
        .frame(height: thumbSize)
    }

    // MARK: - Accessibility copy

    private var accessibilityLabel: String {
        isTriggered
            ? LocalizationHelper.localized("Cancel Emergency SOS")
            : LocalizationHelper.localized("Emergency SOS")
    }

    private var accessibilityValue: String {
        isTriggered
            ? LocalizationHelper.formatted("%@ seconds remaining", String(countdown))
            : ""
    }

    private var accessibilityHint: String {
        isTriggered
            ? LocalizationHelper.localized("Double tap to cancel the countdown")
            : LocalizationHelper.localized("Double tap to start the ten second SOS countdown")
    }

    // MARK: - State transitions (single source of truth for announcements)

    /// Shared entry point for both the physical drag and the accessibility
    /// action so haptics and the spoken announcement fire exactly once.
    private func triggerCountdown() {
        guard !isTriggered else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        startCountdown()
        announce(LocalizationHelper.localized("SOS countdown started. Double tap to cancel."))
    }

    private func startCountdown() {
        isTriggered = true
        countdown = 10
        animationProgress = 1.0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if countdown > 1 {
                countdown -= 1
            } else {
                timer?.invalidate()
                timer = nil
                onTriggered()
                reset()
            }
        }
    }

    private func cancelCountdown() {
        guard isTriggered else { return }
        timer?.invalidate()
        timer = nil
        reset()
        announce(LocalizationHelper.localized("SOS cancelled"))
    }

    private func reset() {
        isTriggered = false
        offset = 0
        animationProgress = 0
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
