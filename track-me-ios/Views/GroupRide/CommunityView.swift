import FirebaseAuth
import MapKit
import SwiftUI

struct CommunityView: View {
    @Bindable private var groupRide = GroupRideManager.shared
    @State private var groupName = "Sunday Riders"
    @State private var joinCode = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showEditSheet = false
    @State private var memberToRemove: String?
    @State private var showCalendarSheet = false
    @State private var showInviteShareSheet = false
    @State private var signedInUserID = Auth.auth().currentUser?.uid
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
            .sheet(isPresented: $showEditSheet) {
                GroupEditView(groupRide: groupRide)
            }
            .sheet(isPresented: $showInviteShareSheet) {
                if let inviteShareMessage {
                    ShareSheet(activityItems: [inviteShareMessage])
                }
            }
            .onAppear {
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

            Section {
                ForEach(memberRows) { row in
                    HStack(spacing: 12) {
                        GroupMemberBadge(initials: row.initials, tint: row.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name)
                            Text(row.status)
                                .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if groupRide.state.isLeader && row.id != Auth.auth().currentUser?.uid {
                            Button(role: .destructive) {
                                memberToRemove = row.id
                            } label: {
                                Label(LocalizationHelper.localized("Remove"), systemImage: "person.crop.circle.badge.minus")
                            }
                        }
                    }
                }
            } header: {
                Text(LocalizationHelper.localized("Roster"))
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
                LabeledContent(LocalizationHelper.localized("Start time"), value: startTimeText)
                if calendarDetails != nil {
                    Button {
                        showCalendarSheet = true
                    } label: {
                        Label(LocalizationHelper.localized("Add to calendar"), systemImage: "calendar.badge.plus")
                    }
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
        return groupRide.state.roster.enumerated().map { index, entry in
            let position = positions[entry.uid]
            return GroupMemberRow(
                id: entry.uid,
                name: entry.displayName ?? entry.initials ?? LocalizationHelper.localized("Rider"),
                initials: entry.initials ?? GroupWire.initials(for: entry.displayName) ?? "?",
                tint: GroupMemberTint.color(index: index),
                status: statusText(for: position)
            )
        }
    }

    private var timeLeftText: String {
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

    private func statusText(for position: GroupWire.MemberPosition?) -> String {
        guard let position else { return LocalizationHelper.localized("No recent location") }
        let ageMillis = Date().timeIntervalSince1970 * 1000 - Double(position.serverTsMillis)
        if ageMillis > Double(max(20, groupRide.state.syncIntervalSec * 2) * 1000) {
            return LocalizationHelper.localized("No recent location")
        }
        return position.riding
            ? LocalizationHelper.localized("Riding")
            : LocalizationHelper.localized("Joined, not started")
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
        !hasStartTime || startTime < Date(timeIntervalSince1970: TimeInterval(groupRide.state.expiresAtMillis) / 1000)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let lat = fixedLocaleDouble(latText)
            let lng = fixedLocaleDouble(lngText)
            let millis = hasStartTime ? Int64(startTime.timeIntervalSince1970 * 1000) : nil
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
    let status: String
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
