import FirebaseAuth
import MapKit
import SwiftUI

struct CommunityView: View {
    @Bindable private var groupRide = GroupRideManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = "Sunday Riders"
    @State private var joinCode = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showEditSheet = false
    @State private var memberToRemove: String?
    @State private var showCalendarSheet = false
    @State private var showInviteShareSheet = false
    @State private var showStatusPicker = false
    @State private var directionsTarget: GroupDirectionsTarget?
    @State private var groupClockTick = StatusAge.elapsedMillis()
    @State private var signedInUserID = AppRuntime.isAppStoreCapture
        ? "capture-owner"
        : Auth.auth().currentUser?.uid
    @State private var authListener: AuthStateDidChangeListenerHandle?

    var body: some View {
        NavigationStack {
            Group {
                if signedInUserID == nil {
                    signedOutView
                } else if groupRide.state.isActive {
                    activeGroupView
                } else if groupRide.endNotice != nil {
                    endNoticeView
                } else {
                    idleGroupView
                }
            }
            .navigationTitle(groupRide.state.groupName ?? LocalizationHelper.localized("Community"))
            .toolbar {
                if groupRide.state.isActive {
                    if groupRide.state.isLeader {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showEditSheet = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel(LocalizationHelper.localized("Edit group"))
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if inviteShareMessage != nil {
                            Button {
                                TelemetryManager.shared.trackGroupInviteSent()
                                showInviteShareSheet = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel(LocalizationHelper.localized("Share group invite"))
                        }
                    }
                }
            }
            .alert("Group Ride", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(LocalizationHelper.localized("OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                LocalizationHelper.localized("Remove member?"),
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                )
            ) {
                Button(LocalizationHelper.localized("Cancel"), role: .cancel) { memberToRemove = nil }
                Button(LocalizationHelper.localized("Remove"), role: .destructive) {
                    guard let uid = memberToRemove else { return }
                    memberToRemove = nil
                    awaitRun { try await groupRide.removeMember(uid: uid) }
                }
            } message: {
                Text(LocalizationHelper.localized("They will be told they are no longer in this group."))
            }
            .task(id: groupRide.pendingJoinCode) {
                guard let code = groupRide.pendingJoinCode else { return }
                joinCode = code
            }
            .task(id: groupRide.pendingJoinToken) {
                guard let token = groupRide.pendingJoinToken else { return }
                await run {
                    try await groupRide.joinByToken(token)
                    groupRide.pendingJoinToken = nil
                    groupRide.pendingJoinViaCode = true
                }
            }
            .task(id: groupRide.state.isActive) {
                guard groupRide.state.isActive else { return }
                while !Task.isCancelled {
                    groupClockTick = StatusAge.elapsedMillis()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .sheet(isPresented: $showEditSheet) {
                GroupEditView(groupRide: groupRide)
            }
            .sheet(isPresented: $showInviteShareSheet) {
                if let inviteShareMessage {
                    ShareSheet(activityItems: [inviteShareMessage])
                }
            }
            .sheet(isPresented: $showStatusPicker) {
                GroupStatusPicker(
                    currentStatus: groupRide.state.selfStatus,
                    persona: StatusPersona(ridePersona: TrackingManager.shared.currentRideId == nil ? nil : TrackingManager.shared.selectedPersona),
                    onSelect: { status in
                        do {
                            try groupRide.setStatus(status)
                            showStatusPicker = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    },
                    onClear: {
                        groupRide.clearStatus()
                        showStatusPicker = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                LocalizationHelper.localized("Directions to last known point"),
                isPresented: Binding(
                    get: { directionsTarget != nil },
                    set: { if !$0 { directionsTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let target = directionsTarget {
                    Button(LocalizationHelper.localized("Apple Maps")) {
                        openDirections(target, provider: .apple)
                    }
                    if GroupDirectionsProvider.google.isAvailable {
                        Button(LocalizationHelper.localized("Google Maps")) {
                            openDirections(target, provider: .google)
                        }
                    }
                }
                Button(LocalizationHelper.localized("Cancel"), role: .cancel) {
                    directionsTarget = nil
                }
            }
            .onAppear {
                guard !AppRuntime.isAppStoreCapture else { return }
                guard authListener == nil else { return }
                authListener = Auth.auth().addStateDidChangeListener { _, user in
                    Task { @MainActor in
                        signedInUserID = user?.uid
                    }
                }
            }
            .onDisappear {
                if let authListener {
                    Auth.auth().removeStateDidChangeListener(authListener)
                    self.authListener = nil
                }
            }
        }
    }

    private var signedOutView: some View {
        ContentUnavailableView {
            Label(LocalizationHelper.localized("Sign in to join a group"), systemImage: "person.2")
        } description: {
            Text(LocalizationHelper.localized("Group Ride shares your live location only with members while the group is live."))
        }
    }

    private var idleGroupView: some View {
        List {
            Section {
                TextField(LocalizationHelper.localized("Group name"), text: $groupName)
                    .textInputAutocapitalization(.words)
                Button {
                    awaitRun { try await groupRide.createGroup(groupName: groupName) }
                } label: {
                    Label(LocalizationHelper.localized("Create group"), systemImage: "plus.circle.fill")
                }
                .disabled(isBusy || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(LocalizationHelper.localized("Create"))
            } footer: {
                Text(LocalizationHelper.localized("The relay cannot read where anyone is. Members can see each other only while the group is live."))
            }

            Section {
                TextField(LocalizationHelper.localized("Join code"), text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: joinCode) { _, value in
                        groupRide.noteJoinCodeEdited(value)
                    }
                Button {
                    awaitRun {
                        try await groupRide.joinByCode(joinCode, viaCode: groupRide.pendingJoinViaCode)
                        groupRide.pendingJoinCode = nil
                        groupRide.pendingJoinViaCode = true
                    }
                } label: {
                    Label(LocalizationHelper.localized("Join group"), systemImage: "person.badge.plus")
                }
                .disabled(isBusy || joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(LocalizationHelper.localized("Join"))
            } footer: {
                Text(LocalizationHelper.localized("They'll see your location while the group is live."))
            }
        }
        .disabled(isBusy)
        .overlay {
            if isBusy { ProgressView().controlSize(.large) }
        }
    }

    private var activeGroupView: some View {
        List {
            if let notice = groupRide.endNotice {
                Section {
                    Text(endNoticeText(notice))
                        .foregroundStyle(BrandColor.warning)
                    Button(LocalizationHelper.localized("OK")) {
                        groupRide.acknowledgeEndNotice()
                    }
                }
            }

            Section {
                LabeledContent(LocalizationHelper.localized("Code"), value: groupRide.state.joinCode ?? "--")
                LabeledContent(LocalizationHelper.localized("Members"), value: "\(groupRide.state.memberCount)/\(max(groupRide.state.maxMembers, 5))")
                LabeledContent(LocalizationHelper.localized("Time left"), value: timeLeftText)
                if groupRide.state.status == .degraded {
                    Text(LocalizationHelper.localized("Group sharing is temporarily unavailable — retrying."))
                        .foregroundStyle(BrandColor.warning)
                }
                if !groupRide.state.isSharingPosition {
                    Text(LocalizationHelper.localized("You're not sharing your location. Others can't see you."))
                        .foregroundStyle(BrandColor.warning)
                }
            } header: {
                Text(LocalizationHelper.localized("Group"))
            }

            if !attentionRows.isEmpty {
                Section {
                    ForEach(attentionRows) { row in
                        rosterRow(row)
                    }
                } header: {
                    HStack {
                        Text(LocalizationHelper.localized("Needs the group"))
                        Spacer()
                        Button(groupRide.state.alertsMuted
                            ? LocalizationHelper.localized("Unmute alerts")
                            : LocalizationHelper.localized("Mute alerts")) {
                            groupRide.setAlertsMuted(!groupRide.state.alertsMuted)
                        }
                        .textCase(nil)
                        .font(.caption.bold())
                    }
                }
            }

            Section {
                ForEach(regularRows) { row in
                    rosterRow(row)
                }
            } header: {
                Text(LocalizationHelper.localized("In this group"))
            }

            Section {
                if let lat = groupRide.state.destinationLat,
                   let lng = groupRide.state.destinationLng,
                   let url = GroupDestinationLinks.appleMapsURL(lat: lat, lng: lng) {
                    Link(destination: url) {
                        Label(LocalizationHelper.localized("Open in Maps"), systemImage: "map")
                    }
                } else {
                    LabeledContent(LocalizationHelper.localized("Destination"), value: "--")
                }
                LabeledContent {
                    HStack(spacing: 4) {
                        Text(startTimeText)
                        if calendarDetails != nil {
                            Button {
                                showCalendarSheet = true
                            } label: {
                                Image(systemName: "calendar.badge.plus")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(BrandColor.primary)
                            .accessibilityLabel(LocalizationHelper.localized("Add to calendar"))
                        }
                    }
                } label: {
                    Text(LocalizationHelper.localized("Start time"))
                }
            }

            Section {
                if groupRide.state.isLeader && groupRide.state.status == .preparing {
                    Button {
                        awaitRun { try await groupRide.startGroup() }
                    } label: {
                        Label(LocalizationHelper.localized("Start group"), systemImage: "play.fill")
                    }
                }
                if groupRide.state.isLeader {
                    Button(role: .destructive) {
                        awaitRun { try await groupRide.endGroup() }
                    } label: {
                        Label(LocalizationHelper.localized("End group"), systemImage: "xmark.circle")
                    }
                }
                Button(role: .destructive) {
                    awaitRun { await groupRide.leaveGroup() }
                } label: {
                    Label(LocalizationHelper.localized("Leave group"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .disabled(isBusy)
        .sheet(isPresented: $showCalendarSheet) {
            if let details = calendarDetails {
                GroupCalendarEditor(
                    title: details.title,
                    startDate: details.startDate,
                    endDate: details.endDate,
                    location: details.location
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if groupRide.state.isStatusUndoAvailable {
                HStack(spacing: 12) {
                    Text(LocalizationHelper.localized("Status will be shared in 4 seconds."))
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Button(LocalizationHelper.localized("Undo")) {
                        groupRide.undoPendingAlertStatus()
                    }
                    .font(.subheadline.bold())
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private var endNoticeView: some View {
        ContentUnavailableView {
            Label(LocalizationHelper.localized("Group Ride ended"), systemImage: "person.2.slash")
        } description: {
            Text(endNoticeText(groupRide.endNotice!))
        } actions: {
            Button(LocalizationHelper.localized("OK")) {
                groupRide.acknowledgeEndNotice()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var inviteShareMessage: String? {
        guard let code = groupRide.state.joinCode,
              let url = groupRide.inviteShareURL() else { return nil }
        return LocalizationHelper.formatted(
            "Join my TrackMe group.\nCode: %@\nLink: %@",
            code,
            url.absoluteString
        )
    }

    private var memberRows: [GroupMemberRow] {
        let positions = Dictionary(uniqueKeysWithValues: groupRide.state.positions.map { ($0.uid, $0) })
        let statuses = Dictionary(uniqueKeysWithValues: groupRide.state.statuses.map { ($0.uid, $0) })
        let selfUID = signedInUserID
        let orderedRoster = groupRide.state.roster.sorted { lhs, rhs in
            if lhs.uid == selfUID { return true }
            if rhs.uid == selfUID { return false }
            return lhs.uid < rhs.uid
        }
        return orderedRoster.enumerated().map { index, entry in
            let isSelf = entry.uid == selfUID
            let position = positions[entry.uid]
            let memberStatus = isSelf
                ? groupRide.state.selfStatus.map {
                    GroupWire.MemberStatus(
                        uid: entry.uid,
                        status: $0,
                        serverTsMillis: 0,
                        ageAnchor: groupRide.state.selfStatusAgeAnchor ?? .unknown(receivedAtElapsedMillis: groupClockTick)
                    )
                }
                : statuses[entry.uid]
            let positionBucket = position?.ageAnchor.map {
                StatusAge.bucket(anchor: $0, nowElapsedMillis: groupClockTick, syncIntervalSec: groupRide.state.syncIntervalSec)
            } ?? .unknown
            let isFresh = position.map { isPositionFresh($0) } ?? false
            let activity = activityText(position: position, isSelf: isSelf)
            let statusLine = statusLine(memberStatus, isSelf: isSelf)
            return GroupMemberRow(
                id: entry.uid,
                name: entry.displayName ?? entry.initials ?? LocalizationHelper.localized("Rider"),
                initials: entry.initials ?? GroupWire.initials(for: entry.displayName) ?? "?",
                tint: GroupMemberTint.color(index: index),
                isSelf: isSelf,
                activity: activity,
                statusLine: statusLine,
                riderStatus: memberStatus?.status,
                position: position,
                positionAge: positionBucket,
                isFresh: isFresh
            )
        }
    }

    private var attentionRows: [GroupMemberRow] {
        memberRows.filter { !$0.isSelf && $0.riderStatus?.isAlert == true }
    }

    private var regularRows: [GroupMemberRow] {
        memberRows.filter { $0.isSelf || $0.riderStatus?.isAlert != true }
    }

    @ViewBuilder
    private func rosterRow(_ row: GroupMemberRow) -> some View {
        GroupRosterRowView(
            row: row,
            canRemove: groupRide.state.isLeader && !row.isSelf,
            onSetStatus: {
                showStatusPicker = true
            },
            onDirections: {
                guard let position = row.position else { return }
                directionsTarget = GroupDirectionsTarget(position: position, age: row.positionAge)
            },
            onShowOnMap: {
                guard row.position != nil else {
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("This rider has no current location to show."),
                        style: .info
                    )
                    return
                }
                groupRide.requestMapFocus(uid: row.id)
                // When Community is presented as Home's sheet, return to the
                // map after dispatching the one-shot focus request. In the
                // Community tab this dismiss is a harmless no-op (§4).
                dismiss()
            },
            onRemove: {
                memberToRemove = row.id
            }
        )
        .groupAccessibilityAction(
            enabled: row.isSelf,
            name: LocalizationHelper.localized("Set status")
        ) {
            showStatusPicker = true
        }
        .groupAccessibilityAction(
            enabled: row.position != nil && !row.isSelf,
            name: directionsLabel(for: row)
        ) {
            if let position = row.position {
                directionsTarget = GroupDirectionsTarget(position: position, age: row.positionAge)
            }
        }
        .groupAccessibilityAction(
            enabled: groupRide.state.isLeader && !row.isSelf,
            name: LocalizationHelper.localized("Remove")
        ) {
            memberToRemove = row.id
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let position = row.position, !row.isSelf {
                Button {
                    directionsTarget = GroupDirectionsTarget(position: position, age: row.positionAge)
                } label: {
                    Label(directionsLabel(for: row), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .tint(BrandColor.primary)
            }
            if groupRide.state.isLeader && !row.isSelf {
                Button(role: .destructive) {
                    memberToRemove = row.id
                } label: {
                    Label(LocalizationHelper.localized("Remove"), systemImage: "person.crop.circle.badge.minus")
                }
            }
        }
    }

    private func directionsLabel(for row: GroupMemberRow) -> String {
        guard let age = GroupAgePresentation.text(row.positionAge) else {
            return LocalizationHelper.localized("Directions")
        }
        return "\(LocalizationHelper.localized("Directions")) · \(age)"
    }

    private var timeLeftText: String {
        guard groupRide.state.hasStarted else {
            return LocalizationHelper.localized("Not started")
        }
        let seconds = max(0, Int(Date(timeIntervalSince1970: TimeInterval(groupRide.state.expiresAtMillis) / 1000).timeIntervalSinceNow))
        if seconds == 0 { return "--" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var startTimeText: String {
        guard let millis = groupRide.state.startAtMillis else { return "--" }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    private var calendarDetails: CalendarDetails? {
        guard let millis = groupRide.state.startAtMillis,
              let groupId = groupRide.state.groupId else { return nil }
        let startDate = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let endDate = Date(timeIntervalSince1970: TimeInterval(groupRide.state.expiresAtMillis) / 1000)
        guard endDate > startDate else { return nil }
        let location: String? = if let lat = groupRide.state.destinationLat,
                                  let lng = groupRide.state.destinationLng {
            GroupDestinationLinks.calendarLocation(lat: lat, lng: lng)
        } else {
            nil
        }
        return CalendarDetails(
            id: groupId,
            title: groupRide.state.groupName ?? LocalizationHelper.localized("Group Ride"),
            startDate: startDate,
            endDate: endDate,
            location: location
        )
    }

    private func activityText(position: GroupWire.MemberPosition?, isSelf: Bool) -> String {
        if isSelf {
            let base = TrackingManager.shared.currentRideId != nil
                ? LocalizationHelper.localized("Riding")
                : LocalizationHelper.localized("Joined, not started")
            guard let ack = groupRide.state.lastOwnPositionAckElapsedMillis else {
                return base
            }
            let age = max(0, groupClockTick - ack)
            guard age >= Int64(max(1, groupRide.state.syncIntervalSec)) * 1_000 else { return base }
            let bucket = StatusAge.bucket(ageMillis: age, syncIntervalSec: groupRide.state.syncIntervalSec)
            return GroupAgePresentation.text(bucket).map {
                LocalizationHelper.formatted("Last shared %@", $0)
            } ?? base
        }
        guard let position else { return LocalizationHelper.localized("No recent location") }
        guard let anchor = position.ageAnchor, anchor.isKnown else {
            return LocalizationHelper.localized("No recent location")
        }
        let base = position.riding
            ? LocalizationHelper.localized("Riding")
            : LocalizationHelper.localized("Joined, not started")
        let bucket = StatusAge.bucket(anchor: anchor, nowElapsedMillis: groupClockTick, syncIntervalSec: groupRide.state.syncIntervalSec)
        return GroupAgePresentation.text(bucket).map { "\(base) · \($0)" } ?? base
    }

    private func statusLine(_ memberStatus: GroupWire.MemberStatus?, isSelf: Bool) -> String? {
        guard let memberStatus else { return nil }
        let label = RiderStatusPresentation.label(for: memberStatus.status)
        if isSelf {
            if groupRide.state.isClearingStatus {
                return "\(label) · \(LocalizationHelper.localized("Clearing…"))"
            }
            if !groupRide.state.isSelfStatusAcknowledged {
                return "\(label) · \(LocalizationHelper.localized("Not sent yet"))"
            }
        }
        let bucket = StatusAge.bucket(
            anchor: memberStatus.ageAnchor,
            nowElapsedMillis: groupClockTick,
            syncIntervalSec: groupRide.state.syncIntervalSec
        )
        return GroupAgePresentation.text(bucket, includesAgo: false).map { "\(label) · \($0)" } ?? label
    }

    private func isPositionFresh(_ position: GroupWire.MemberPosition) -> Bool {
        guard let anchor = position.ageAnchor, anchor.isKnown else { return false }
        let age = StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: groupClockTick)
        return age < Int64(max(20, groupRide.state.syncIntervalSec * 2)) * 1_000
    }

    private func openDirections(_ target: GroupDirectionsTarget, provider: GroupDirectionsProvider) {
        directionsTarget = nil
        guard let url = provider.url(lat: target.position.lat, lng: target.position.lng) else {
            ToastManager.shared.show(message: LocalizationHelper.localized("No maps app is available."), style: .warning)
            return
        }
        let ageBucket = GroupAgePresentation.telemetryBucket(target.age)
        UIApplication.shared.open(url) { opened in
            if opened {
                TelemetryManager.shared.trackGroupDirectionsOpened(ageBucket: ageBucket)
            } else {
                ToastManager.shared.show(message: LocalizationHelper.localized("No maps app is available."), style: .warning)
            }
        }
    }

    private func endNoticeText(_ notice: GroupEndNotice) -> String {
        switch notice.reason {
        case .removed:
            return LocalizationHelper.localized("You're no longer in this group.")
        case .expired, .ended:
            if notice.rideStillRecording {
                return LocalizationHelper.localized("This group has ended. Your ride is still recording.")
            }
            return LocalizationHelper.localized("This group has ended.")
        }
    }

    private func awaitRun(_ action: @escaping () async throws -> Void) {
        Task { await run(action) }
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GroupEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var groupRide: GroupRideManager
    @State private var latText = ""
    @State private var lngText = ""
    @State private var hasStartTime = false
    @State private var startTime = Date().addingTimeInterval(15 * 60)
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LocalizationHelper.localized("Latitude"), text: $latText)
                        .keyboardType(.decimalPad)
                    TextField(LocalizationHelper.localized("Longitude"), text: $lngText)
                        .keyboardType(.decimalPad)
                } header: {
                    Text(LocalizationHelper.localized("Destination"))
                } footer: {
                    Text(LocalizationHelper.localized("Leave both fields blank to clear the destination."))
                }

                if !groupRide.state.hasStarted {
                    Section {
                        Toggle(LocalizationHelper.localized("Scheduled start"), isOn: $hasStartTime)
                        if hasStartTime {
                            DatePicker(
                                LocalizationHelper.localized("Start time"),
                                selection: $startTime,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    } footer: {
                        Text(LocalizationHelper.localized("A scheduled start sends a reminder only. Sharing never starts automatically."))
                    }
                }
            }
            .navigationTitle(LocalizationHelper.localized("Edit group"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationHelper.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationHelper.localized("Save")) {
                        Task { await save() }
                    }
                    .disabled(isSaving || !destinationIsValid || !scheduledStartIsValid)
                }
            }
            .onAppear {
                if let lat = groupRide.state.destinationLat, let lng = groupRide.state.destinationLng {
                    latText = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), lat)
                    lngText = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), lng)
                }
                if let millis = groupRide.state.startAtMillis {
                    hasStartTime = true
                    startTime = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
                }
            }
            .alert("Group Ride", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(LocalizationHelper.localized("OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var destinationIsValid: Bool {
        let latBlank = latText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lngBlank = lngText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if latBlank && lngBlank { return true }
        guard let lat = fixedLocaleDouble(latText), let lng = fixedLocaleDouble(lngText) else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lng)
    }

    private var scheduledStartIsValid: Bool {
        groupRide.state.hasStarted
            || !hasStartTime
            || startTime < Date(timeIntervalSince1970: TimeInterval(groupRide.state.expiresAtMillis) / 1000)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let lat = fixedLocaleDouble(latText)
            let lng = fixedLocaleDouble(lngText)
            let millis = groupRide.state.hasStarted
                ? groupRide.state.startAtMillis
                : (hasStartTime ? Int64(startTime.timeIntervalSince1970 * 1000) : nil)
            try await groupRide.updateMeta(destinationLat: lat, destinationLng: lng, startAtMillis: millis)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fixedLocaleDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

private struct GroupMemberRow: Identifiable {
    let id: String
    let name: String
    let initials: String
    let tint: Color
    let isSelf: Bool
    let activity: String
    let statusLine: String?
    let riderStatus: RiderStatus?
    let position: GroupWire.MemberPosition?
    let positionAge: StatusAge.Bucket
    let isFresh: Bool
}

private struct GroupRosterRowView: View {
    let row: GroupMemberRow
    let canRemove: Bool
    let onSetStatus: () -> Void
    let onDirections: () -> Void
    let onShowOnMap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if row.isSelf {
                leadingContent
            } else {
                Button(action: onShowOnMap) {
                    leadingContent
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !row.isSelf {
                HStack(spacing: 8) {
                    if row.position != nil {
                        Button(action: onDirections) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(
                                    row.isFresh ? BrandColor.primary : Color.secondary.opacity(0.55),
                                    in: Circle()
                                )
                                .saturation(row.isFresh ? 1 : 0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }

                    if canRemove {
                        Button(action: onRemove) {
                            Image(systemName: "person.crop.circle.badge.minus")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(BrandColor.sosText)
                                .frame(width: 44, height: 44)
                                .background(BrandColor.sos.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            row.isSelf
                ? LocalizationHelper.localized("Opens your status choices")
                : row.position == nil
                    ? LocalizationHelper.localized("No current location is available")
                    : LocalizationHelper.localized("Shows this rider on the map")
        )
        .accessibilityAction(
            named: Text(row.isSelf
                ? LocalizationHelper.localized("Set status")
                : LocalizationHelper.localized("Show on map"))
        ) {
            row.isSelf ? onSetStatus() : onShowOnMap()
        }
    }

    @ViewBuilder
    private var leadingContent: some View {
        GroupMemberBadge(
            initials: row.initials,
            tint: row.tint,
            isStale: !row.isSelf && !row.isFresh,
            status: row.riderStatus
        )
        .frame(width: 44)

        VStack(alignment: .leading, spacing: 6) {
            Text(row.isSelf ? LocalizationHelper.localized("You") : row.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)

            if let statusLine = row.statusLine, let riderStatus = row.riderStatus {
                statusChip(statusLine, status: riderStatus)
            } else if row.isSelf {
                Button(action: onSetStatus) {
                    Label(LocalizationHelper.localized("Set status"), systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(BrandColor.primary.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            Text(row.activity)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(_ text: String, status: RiderStatus) -> some View {
        let isMuted = !row.isSelf && !row.isFresh
        let color = isMuted ? Color.secondary : RiderStatusPresentation.textColor(status.severity)

        if row.isSelf {
            Button(action: onSetStatus) {
                statusChipContent(text, status: status, color: color, isMuted: isMuted)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        } else {
            statusChipContent(text, status: status, color: color, isMuted: isMuted)
        }
    }

    private func statusChipContent(
        _ text: String,
        status: RiderStatus,
        color: Color,
        isMuted: Bool
    ) -> some View {
        Label(text, systemImage: RiderStatusPresentation.systemImage(status.severity))
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(isMuted ? 0.08 : 0.10), in: Capsule())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts = [row.isSelf ? LocalizationHelper.localized("You") : row.name]
        if let statusLine = row.statusLine, let status = row.riderStatus {
            parts.append("\(RiderStatusPresentation.severityName(status.severity)): \(statusLine)")
        } else if row.isSelf {
            parts.append(LocalizationHelper.localized("No status set"))
        }
        parts.append(row.activity)
        if row.position != nil, let age = GroupAgePresentation.text(row.positionAge) {
            parts.append(LocalizationHelper.formatted("Directions to a last known point updated %@", age))
        }
        return parts.joined(separator: ", ")
    }
}

private struct GroupStatusPicker: View {
    let currentStatus: RiderStatus?
    let persona: StatusPersona
    let onSelect: (RiderStatus) -> Void
    let onClear: () -> Void

    private var options: [RiderStatus] {
        var values = RiderStatusCatalog.options(for: persona)
        if let currentStatus, !values.contains(where: { $0.raw == currentStatus.raw }) {
            values.insert(currentStatus, at: 0)
        }
        return values
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(options) { status in
                    Button {
                        guard status.raw != currentStatus?.raw else { return }
                        onSelect(status)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(RiderStatusPresentation.color(status.severity))
                                    .frame(width: ruleWidth(status.severity), height: 34)
                                Label(
                                    RiderStatusPresentation.label(for: status),
                                    systemImage: RiderStatusPresentation.systemImage(status.severity)
                                )
                                .foregroundStyle(.primary)
                                Spacer()
                                if status.raw == currentStatus?.raw {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(BrandColor.primary)
                                }
                            }
                            if status.isAlert {
                                Text(LocalizationHelper.localized("This tells the people in this group. It does not contact emergency services. They'll see it when their app next syncs."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(RiderStatusPresentation.severityName(status.severity)), \(RiderStatusPresentation.label(for: status))")
                    .accessibilityValue(status.raw == currentStatus?.raw ? LocalizationHelper.localized("Selected") : "")
                }

                if currentStatus != nil {
                    Button(action: onClear) {
                        Label(LocalizationHelper.localized("None"), systemImage: "circle.slash")
                            .frame(minHeight: 48)
                    }
                    .accessibilityLabel(LocalizationHelper.localized("Clear status"))
                }
            }
            .navigationTitle(LocalizationHelper.localized("Your status"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func ruleWidth(_ severity: StatusSeverity) -> CGFloat {
        switch severity {
        case .info: 2
        case .caution: 4
        case .alert: 6
        }
    }
}

private struct GroupDirectionsTarget: Identifiable {
    let id = UUID()
    let position: GroupWire.MemberPosition
    let age: StatusAge.Bucket
}

private struct CalendarDetails: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
}

struct GroupMemberBadge: View {
    let initials: String
    let tint: Color
    var isStale = false
    var ageText: String?
    var status: RiderStatus? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: Circle())
                .overlay(Circle().stroke(BrandColor.primary, lineWidth: 2))
                .saturation(isStale ? 0 : 1)

            if let ageText {
                Text(ageText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.72), in: Capsule())
                    .offset(x: 8, y: 6)
            }

            if let status {
                Image(systemName: RiderStatusPresentation.systemImage(status.severity))
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(RiderStatusPresentation.fillForeground(status.severity))
                    .frame(width: 16, height: 16)
                    .background(RiderStatusPresentation.color(status.severity), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.65), radius: 1, y: 1)
                    .offset(x: 7, y: -25)
                    .saturation(isStale ? 0 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}

enum GroupMemberTint {
    private static let colors: [Color] = [
        BrandColor.primaryFill,
        BrandColor.success,
        BrandColor.warning,
        .indigo,
        .teal
    ]

    static func color(index: Int) -> Color {
        colors[index % colors.count]
    }
}

private extension View {
    @ViewBuilder
    func groupAccessibilityAction(enabled: Bool, name: String, action: @escaping () -> Void) -> some View {
        if enabled {
            accessibilityAction(named: Text(name), action)
        } else {
            self
        }
    }
}
