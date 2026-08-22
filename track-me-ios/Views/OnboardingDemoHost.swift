import SwiftUI

enum OnboardingDemoProgress {
    static let autoAdvanceDelay: Duration = .seconds(4)

    static func nextStep(current: Int, count: Int) -> Int? {
        precondition(count > 0)
        precondition((0..<count).contains(current))
        let next = current + 1
        return next < count ? next : nil
    }

    static func isMeaningfulScrub(startIndex: Int, currentIndex: Int, pointCount: Int) -> Bool {
        guard pointCount >= 2 else { return false }
        let threshold = max(2, Int(Double(pointCount - 1) * 0.25))
        return abs(currentIndex - startIndex) >= threshold
    }
}

/// Shared, service-free progress shell for the two guided onboarding pages.
struct OnboardingDemoHost<Content: View>: View {
    let instructions: [String]
    let onCompleted: () -> Void
    @ViewBuilder let content: (Int, @escaping () -> Void) -> Content

    @State private var step = 0
    @State private var completed = false
    @State private var activityGeneration = 0
    @GestureState private var isInteracting = false

    init(
        instructions: [String],
        onCompleted: @escaping () -> Void,
        @ViewBuilder content: @escaping (Int, @escaping () -> Void) -> Content
    ) {
        precondition(!instructions.isEmpty)
        self.instructions = instructions
        self.onCompleted = onCompleted
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LocalizationHelper.formatted(
                        "Step %d of %d",
                        step + 1,
                        instructions.count
                    ))
                    .font(BrandTypography.caption.weight(.bold))
                    .foregroundStyle(BrandColor.primary)

                    Spacer()

                    Button(LocalizationHelper.localized("Skip step"), action: advance)
                        .font(BrandTypography.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }

                Text(instructions[step])
                    .font(BrandTypography.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)

            content(step, advance)
                .frame(maxWidth: .infinity)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isInteracting) { _, active, _ in
                            active = true
                        }
                )
                .onChange(of: isInteracting) { _, active in
                    if active { activityGeneration &+= 1 }
                }
        }
        .task(id: "\(step)-\(activityGeneration)") {
            guard !completed else { return }
            do {
                try await Task.sleep(for: OnboardingDemoProgress.autoAdvanceDelay)
                advance()
            } catch {
                // A step change cancels its old inactivity timer.
            }
        }
    }

    private func advance() {
        guard !completed else { return }
        if let next = OnboardingDemoProgress.nextStep(current: step, count: instructions.count) {
            step = next
        } else {
            completed = true
            onCompleted()
        }
    }
}
