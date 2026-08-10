import SwiftUI

struct AppUpdateView: View {
    let updateInfo: AppUpdateInfo
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .frame(width: 48, height: 48)
                .foregroundColor(.cyan) // or brand color if available

            Text(LocalizationHelper.localized("Update Available"))
                .font(.title2)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Text("TrackMe v\(updateInfo.latestVersionName)")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.cyan.opacity(0.15))
                .cornerRadius(16)
                .foregroundColor(.cyan)

            ScrollView {
                Text(updateInfo.releaseNotes)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            VStack(spacing: 12) {
                Button(action: {
                    openURL(updateInfo.updateURL)
                }) {
                    Text(LocalizationHelper.localized("Update Now"))
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(BrandColor.primaryFill)
                        .cornerRadius(12)
                }

                Button(action: {
                    onDismiss()
                }) {
                    Text(LocalizationHelper.localized("Later"))
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
        }
        .padding(24)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(24)
        .shadow(radius: 20)
        .padding(24)
    }
}
