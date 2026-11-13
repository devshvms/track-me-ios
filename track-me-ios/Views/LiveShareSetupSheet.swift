import SwiftUI

struct LiveShareSetupSheet: View {
    var liveSharingManager: LiveSharingManager
    let trustedWatchers: [TrustedWatcher]
    let isAuthenticated: Bool
    let groupActive: Bool
    let onDismiss: () -> Void
    let onStartDirectShare: (Int) -> Void
    let onStopShare: () -> Void
    let onShareLink: () -> Void
    let onCopyLink: () -> Void
    let onInviteWatcher: () -> Void
    let onToggleWatcherAutoNotify: (String, Bool) -> Void
    let onRemoveWatcher: (String) -> Void

    @State private var selectedDurationMinutes: Int = 30
    @State private var watcherToRemove: TrustedWatcher? = nil
    @State private var showRemoveConfirmation: Bool = false

    private let durationOptions: [(minutes: Int, key: String)] = [
        (30, "30 min"),
        (60, "1 hr"),
        (120, "2 hr"),
        (1440, "24 hr")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groupActive {
                        noticeCard(
                            text: LocalizationHelper.localized("Solo live sharing is unavailable during a group ride."),
                            background: BrandColor.destructive.opacity(0.14),
                            foreground: BrandColor.destructiveText
                        )
                    } else {
                        Text(LocalizationHelper.localized("Prepare a link valid for 30 minutes. Your location appears while recording. Anyone with the link can view it. Opening this page shares nothing."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !isAuthenticated {
                        noticeCard(
                            text: LocalizationHelper.localized("Sign in to share your live location."),
                            background: Color(uiColor: .secondarySystemGroupedBackground),
                            foreground: .secondary
                        )
                    }

                    if !liveSharingManager.isActive {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizationHelper.localized("Share duration"))
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 8) {
                                ForEach(durationOptions, id: \.minutes) { option in
                                    let isSelected = selectedDurationMinutes == option.minutes
                                    Button {
                                        selectedDurationMinutes = option.minutes
                                        Haptics.selection()
                                    } label: {
                                        Text(LocalizationHelper.localized(option.key))
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .frame(minHeight: 38)
                                            .background(
                                                isSelected ? BrandColor.primaryFill : Color(uiColor: .secondarySystemGroupedBackground),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            )
                                            .foregroundStyle(isSelected ? BrandColor.onPrimary : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(LocalizationHelper.localized("Trusted Watchers"))
                            .font(.subheadline.weight(.semibold))

                        Text(LocalizationHelper.localized("Trusted watchers automatically receive a live push notification when you start sharing. Zero contacts permission required."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if trustedWatchers.isEmpty {
                            Text(LocalizationHelper.localized("No trusted watchers yet. Invite friends or family via link."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        } else {
                            VStack(spacing: 8) {
                                ForEach(trustedWatchers) { watcher in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(watcher.displayName)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(LocalizationHelper.localized("Auto-notify"))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Toggle(
                                            "",
                                            isOn: Binding(
                                                get: { watcher.autoNotify },
                                                set: { enabled in
                                                    onToggleWatcherAutoNotify(watcher.uid, enabled)
                                                }
                                            )
                                        )
                                        .labelsHidden()
                                        .accessibilityLabel(
                                            LocalizationHelper.formatted("Auto-notify %@", watcher.displayName)
                                        )

                                        Button(role: .destructive) {
                                            watcherToRemove = watcher
                                            showRemoveConfirmation = true
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.subheadline)
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(LocalizationHelper.localized("Remove watcher"))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                }
                            }
                        }

                        HStack {
                            Text(LocalizationHelper.localized("Up to 5 trusted watchers"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                onInviteWatcher()
                            } label: {
                                Label(
                                    LocalizationHelper.localized("Invite Watcher"),
                                    systemImage: "person.badge.plus"
                                )
                                .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .disabled(!isAuthenticated || trustedWatchers.count >= TrustedWatchersManager.maxWatchers)
                        }
                    }

                    Divider()

                    if liveSharingManager.isActive {
                        if liveSharingManager.activeViewers > 0 {
                            Label(
                                LocalizationHelper.formatted("%@ watching", String(liveSharingManager.activeViewers)),
                                systemImage: "eye.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BrandColor.primary)
                        }

                        HStack(spacing: 10) {
                            Button {
                                onCopyLink()
                            } label: {
                                Label(LocalizationHelper.localized("Copy link"), systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(liveSharingManager.shareLink == nil)

                            Button {
                                onShareLink()
                            } label: {
                                Label(LocalizationHelper.localized("Share link"), systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(liveSharingManager.shareLink == nil)
                        }

                        Button(role: .destructive) {
                            onStopShare()
                            onDismiss()
                        } label: {
                            Label(LocalizationHelper.localized("Stop sharing"), systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandColor.destructive)
                    } else {
                        Button {
                            onStartDirectShare(selectedDurationMinutes)
                            onDismiss()
                        } label: {
                            Label(
                                LocalizationHelper.localized("Share Live Location"),
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAuthenticated || groupActive || liveSharingManager.isStarting)
                    }
                }
                .padding()
            }
            .navigationTitle(LocalizationHelper.localized("Live sharing"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationHelper.localized("Done")) {
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            LocalizationHelper.localized("Remove trusted watcher?"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible,
            presenting: watcherToRemove
        ) { watcher in
            Button(LocalizationHelper.localized("Remove watcher"), role: .destructive) {
                onRemoveWatcher(watcher.uid)
                watcherToRemove = nil
            }
            Button(LocalizationHelper.localized("Cancel"), role: .cancel) {
                watcherToRemove = nil
            }
        } message: { watcher in
            Text(LocalizationHelper.formatted("Remove %@ from trusted watchers? They will no longer receive live ride alerts automatically.", watcher.displayName))
        }
    }

    private func noticeCard(text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
