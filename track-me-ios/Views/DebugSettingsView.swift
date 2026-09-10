import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("debugModeEnabled") private var debugModeEnabled = false
    @AppStorage("intelligentAutoPause") private var isAutoPauseEnabled = true
    @AppStorage("enableGPSPostProcessing") private var isPostProcessingEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        LocalizationHelper.localized("Debug mode"),
                        isOn: Binding(
                            get: { debugModeEnabled },
                            set: { enabled in
                                guard !enabled else { return }
                                DebugSettings.disableAndReset()
                                isAutoPauseEnabled = true
                                isPostProcessingEnabled = true
                                debugModeEnabled = false
                                dismiss()
                            }
                        )
                    )
                    .tint(BrandColor.primary)

                    Text(LocalizationHelper.localized("Turning this off restores diagnostic settings to defaults and removes this page."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)

                VStack(alignment: .leading, spacing: 16) {
                    Text(LocalizationHelper.localized("Tracking controls"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationHelper.localized("Intelligent Auto-Pause"))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(LocalizationHelper.localized("Dynamically pauses moving time based on the activity speed profile."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $isAutoPauseEnabled)
                            .labelsHidden()
                            .tint(BrandColor.primary)
                            .accessibilityLabel(LocalizationHelper.localized("Intelligent auto-pause"))
                    }

                    Divider()

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationHelper.localized("Disable GPS Post-Processing"))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(LocalizationHelper.localized("Stored diagnostic preference only. iOS currently filters fixes live and has no post-ride pipeline connected to this flag."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !isPostProcessingEnabled },
                            set: { isPostProcessingEnabled = !$0 }
                        ))
                        .labelsHidden()
                        .tint(BrandColor.primary)
                        .accessibilityLabel(LocalizationHelper.localized("Disable GPS post-processing"))
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizationHelper.localized("Debug Settings"))
        .task {
            if !debugModeEnabled { dismiss() }
        }
    }
}
