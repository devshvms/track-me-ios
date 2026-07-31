import SwiftUI

struct AgeRestrictedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColor.primary)
                .accessibilityHidden(true)
            Text("TrackMe")
                .font(.headline)
                .foregroundStyle(BrandColor.primary)
            Text("TrackMe is for adults")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("TrackMe is intended for an adult audience and isn't available to users under 18, per our Privacy Policy. If you believe this is a mistake, please contact us.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.navy900.ignoresSafeArea())
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }
}

struct AgeSignalCheckingView: View {
    var body: some View {
        ProgressView()
            .tint(BrandColor.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
