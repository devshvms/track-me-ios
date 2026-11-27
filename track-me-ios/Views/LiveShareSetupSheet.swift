import SwiftUI

enum HomeLiveSharingTapAction: Equatable {
    case openSetupSheet
    case showGroupActiveBlocked

    static func resolve(
        liveSharingActive: Bool,
        groupActive: Bool,
        isAuthenticated: Bool
    ) -> HomeLiveSharingTapAction {
        if !liveSharingActive && groupActive {
            return .showGroupActiveBlocked
        }
        return .openSetupSheet
    }
}

struct LiveShareSetupFlowState: Equatable {
    var isSheetPresented: Bool = false
    var selectedDurationMinutes: Int = 30
    var isEditingDuration: Bool = false
    var notifyWatchersOnEnd: Bool = true

    var timeLimitSummaryText: String {
        LocalizationHelper.formatted(
            "Sharing time limit · %@",
            LiveShareSetupSheet.formatDuration(selectedDurationMinutes)
        )
    }

    @discardableResult
    mutating func handleHomeTap(
        liveSharingActive: Bool,
        groupActive: Bool,
        isAuthenticated: Bool
    ) -> HomeLiveSharingTapAction {
        let action = HomeLiveSharingTapAction.resolve(
            liveSharingActive: liveSharingActive,
            groupActive: groupActive,
            isAuthenticated: isAuthenticated
        )
        if action == .openSetupSheet {
            isSheetPresented = true
            selectedDurationMinutes = 30
            isEditingDuration = false
            notifyWatchersOnEnd = true
        }
        return action
    }

    mutating func toggleDurationEditor() {
        isEditingDuration.toggle()
    }

    mutating func selectDuration(minutes: Int) {
        guard LiveShareSetupSheet.durationOptions.contains(minutes) else { return }
        selectedDurationMinutes = minutes
    }

    mutating func confirmStart(onStartDirectShare: (Int) -> Void) {
        let duration = selectedDurationMinutes
        isSheetPresented = false
        isEditingDuration = false
        onStartDirectShare(duration)
    }

    mutating func confirmStart(onStartDirectShareWithAssurance: (Int, Bool) -> Void) {
        let duration = selectedDurationMinutes
        let notifyOnEnd = notifyWatchersOnEnd
        isSheetPresented = false
        isEditingDuration = false
        onStartDirectShareWithAssurance(duration, notifyOnEnd)
    }
}

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
    var stopsWithRide: Bool = true
    var onStartDirectShareWithAssurance: ((Int, Bool) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var flowState = LiveShareSetupFlowState(isSheetPresented: true)
    @State private var watcherToRemove: TrustedWatcher? = nil
    @State private var showRemoveConfirmation: Bool = false

    static let durationOptions: [Int] = [30, 60, 120, 1440]

    static func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 && minutes % 60 == 0 {
            return LocalizationHelper.formatted("%@ hr", String(minutes / 60))
        }
        return LocalizationHelper.formatted("%@ min", String(minutes))
    }

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
                        Text(LocalizationHelper.localized("Anyone with the link can view your live location. Opening this page shares nothing."))
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
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 12) {
                                    Text(flowState.timeLimitSummaryText)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        if reduceMotion {
                                            flowState.toggleDurationEditor()
                                        } else {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                flowState.toggleDurationEditor()
                                            }
                                        }
                                    } label: {
                                        Text(LocalizationHelper.localized(flowState.isEditingDuration ? "Done" : "Change"))
                                            .font(.subheadline.weight(.semibold))
                                            .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(BrandColor.primary)
                                }

                                if flowState.isEditingDuration {
                                    let columns = Array(
                                        repeating: GridItem(.flexible(), spacing: 8),
                                        count: dynamicTypeSize >= .accessibility1 ? 2 : 4
                                    )
                                    LazyVGrid(columns: columns, spacing: 8) {
                                        ForEach(Self.durationOptions, id: \.self) { minutes in
                                            let isSelected = flowState.selectedDurationMinutes == minutes
                                            Button {
                                                flowState.selectDuration(minutes: minutes)
                                                Haptics.selection()
                                            } label: {
                                                Text(Self.formatDuration(minutes))
                                                    .font(.subheadline.weight(.semibold))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.8)
                                                    .frame(maxWidth: .infinity)
                                                    .frame(minHeight: 44)
                                                    .background(
                                                        isSelected ? BrandColor.primaryFill : Color(uiColor: .tertiarySystemGroupedBackground),
                                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    )
                                                    .foregroundStyle(isSelected ? BrandColor.onPrimary : .primary)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                            let expiryBase = LocalizationHelper.localized("Sharing stops automatically at this limit. You can stop it sooner.")
                            let expiryCopy = stopsWithRide
                                ? "\(expiryBase) \(LocalizationHelper.localized("Ending your ride also stops sharing."))"
                                : expiryBase
                            Text(expiryCopy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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

                        if !liveSharingManager.isActive && trustedWatchers.contains(where: { $0.autoNotify }) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizationHelper.localized("Notify selected watchers when I end this trip"))
                                        .font(.subheadline.weight(.medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(LocalizationHelper.localized("Sends a trip-ended update only when you manually stop sharing."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: $flowState.notifyWatchersOnEnd)
                                    .labelsHidden()
                                    .accessibilityLabel(LocalizationHelper.localized("Notify selected watchers when I end this trip"))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        }
                    }

                    Divider()

                    if liveSharingManager.isActive {
                        if liveSharingManager.activeViewers > 0 {
                            Label(
                                LocalizationHelper.formatted("%@ watching live", String(liveSharingManager.activeViewers)),
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
                            if let onStartDirectShareWithAssurance {
                                flowState.confirmStart(onStartDirectShareWithAssurance: onStartDirectShareWithAssurance)
                            } else {
                                flowState.confirmStart(onStartDirectShare: onStartDirectShare)
                            }
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
