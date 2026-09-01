import SwiftUI
import FirebaseAuth

struct AccountManagementView: View {
    @State private var showSignOutWarning = false
    @State private var showDeleteCloudWarning = false
    @State private var showDeleteAccountWarning = false

    @State private var feedbackText = ""
    @State private var confirmText = ""
    @State private var isDeleting = false

    @State private var isPrivacyExpanded = false

    @State private var isRequestingExport = false
    @State private var showExportConfirmationModal = false
    @State private var exportErrorMessage: String? = nil
    @State private var showExportErrorAlert = false
    @State private var currentExportResponse: DataExportResponse? = nil
    @State private var isDownloadingArchive = false
    @State private var downloadedArchiveURL: URL? = nil

    /// TASK-277: the same earned ring the Settings header wears, at the size Android uses here.
    /// Derived on appear rather than observed: this screen is pushed, not long-lived, and a level
    /// cannot change while it is open.
    @State private var levelIndex: Int = 0

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile Section
                VStack(spacing: 12) {
                    LevelAvatar(levelIndex: levelIndex, diameter: 100) {
                        if let photoUrl = Auth.auth().currentUser?.photoURL {
                            AsyncImage(url: photoUrl) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                        } else {
                            ZStack {
                                Circle().fill(Color.gray.opacity(0.3))
                                Image(systemName: "person.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 50, height: 50)
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    Text(Auth.auth().currentUser?.displayName ?? "Explorer")
                        .font(.title2).bold()
                        .foregroundColor(.primary)

                    Text(Auth.auth().currentUser?.email ?? "")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 24)

                // Sign Out Button
                Button(action: { showSignOutWarning = true }) {
                    Text("Sign Out")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.clear)
                        .foregroundColor(.primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                }

                // On-demand Data Archive Export Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "archivebox.fill")
                            .foregroundColor(BrandColor.primary)
                        Text("Data Archive & Export")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        if let status = currentExportResponse?.status {
                            Text(status)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(status == "COMPLETED" ? BrandColor.success.opacity(0.2) : BrandColor.warning.opacity(0.2))
                                .foregroundColor(status == "COMPLETED" ? BrandColor.success : BrandColor.warningText)
                                .clipShape(Capsule())
                        }
                    }

                    Text("Request a comprehensive archive of your synchronized ride history (GPX files & JSON metadata). The ZIP is assembled when you download it and expires six hours after retrieval, or after 48 hours if untouched.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    if currentExportResponse?.status == "COMPLETED", let downloadUrl = currentExportResponse?.downloadUrl, let url = URL(string: downloadUrl) {
                        Button(action: {
                            guard !isDownloadingArchive else { return }
                            isDownloadingArchive = true
                            DataExportService.shared.downloadArchive(from: url) { result in
                                isDownloadingArchive = false
                                switch result {
                                case .success(let fileURL):
                                    downloadedArchiveURL = fileURL
                                case .failure(let error):
                                    exportErrorMessage = error.localizedDescription
                                    showExportErrorAlert = true
                                }
                            }
                        }) {
                            HStack {
                                if isDownloadingArchive {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(isDownloadingArchive ? "Preparing Archive..." : "Download Archive (.zip)")
                                    .font(.subheadline).bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(BrandColor.primaryFill)
                            .foregroundColor(.white)
                            .cornerRadius(24)
                        }
                        .disabled(isDownloadingArchive)
                    } else {
                        Button(action: {
                            guard !isRequestingExport else { return }
                            isRequestingExport = true
                            DataExportService.shared.requestDataArchiveExport { result in
                                isRequestingExport = false
                                switch result {
                                case .success(let response):
                                    currentExportResponse = response
                                    if response.status != "COMPLETED" {
                                        showExportConfirmationModal = true
                                    }
                                case .failure(let error):
                                    exportErrorMessage = error.localizedDescription
                                    showExportErrorAlert = true
                                }
                            }
                        }) {
                            HStack {
                                if isRequestingExport {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.doc.fill")
                                }
                                Text("Download All My Data (GPX/JSON Archive)")
                                    .font(.subheadline).bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(BrandColor.primaryFill)
                            .foregroundColor(.white)
                            .cornerRadius(24)
                        }
                        .disabled(isRequestingExport)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)

                // Privacy and Security Card
                VStack(spacing: 0) {
                    Button(action: {
                        withAnimation {
                            isPrivacyExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Text("Privacy and Security")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: isPrivacyExpanded ? "chevron.up" : "chevron.down")
                                .foregroundColor(.gray)
                        }
                        .padding()
                    }

                    if isPrivacyExpanded {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(LocalizationHelper.localized("Privacy Policy\n\nYour data is completely under your control. We only store data locally by default. If you enable Cloud Sync, your rides are securely stored on our servers. You can permanently delete your synced data or your entire account at any time using the options below. Deleted data cannot be recovered."))
                                .font(.caption)
                                .foregroundColor(.gray)

                            Button(action: { showDeleteCloudWarning = true }) {
                                Text("Delete Cloud Data")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.clear)
                                    .foregroundColor(BrandColor.destructiveText)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24)
                                            .stroke(BrandColor.destructive.opacity(0.5), lineWidth: 1)
                                    )
                            }

                            Button(action: { showDeleteAccountWarning = true }) {
                                Text("Delete Account & Data")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(BrandColor.destructive.opacity(0.15))
                                    .foregroundColor(BrandColor.destructiveText)
                                    .cornerRadius(24)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
        .navigationTitle("Account Management")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out Warning", isPresented: $showSignOutWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                Task {
                    await AuthManager.shared.signOut()
                    dismiss()
                }
            }
        } message: {
            Text(LocalizationHelper.localized("Signing out will stop any active live share and clear synced rides from this phone. They remain safely in the cloud, and new rides continue to be saved locally. Are you sure you want to sign out?"))
        }
        .alert("Delete Cloud Data", isPresented: $showDeleteCloudWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    try? await AuthManager.shared.deleteCloudData()
                }
            }
        } message: {
            Text("Are you sure you want to delete all your synced rides from the cloud? This action cannot be undone.")
        }
        .alert("Delete Account", isPresented: $showDeleteAccountWarning) {
            TextField("Why are you leaving? (Optional)", text: $feedbackText)
            TextField("Type DELETE to confirm", text: $confirmText)
            Button("Cancel", role: .cancel) { }
            Button("Delete Everything", role: .destructive) {
                guard confirmText == "DELETE" else { return }
                Task {
                    isDeleting = true
                    defer { isDeleting = false }
                    do {
                        try await AuthManager.shared.deleteAccountAndData(feedback: feedbackText)
                        dismiss()
                    } catch {
                        ToastManager.shared.show(
                            message: Self.deletionErrorMessage(for: error),
                            style: .error
                        )
                    }
                }
            }
            .disabled(confirmText != "DELETE" || isDeleting)
        } message: {
            Text("This is a permanent action. Your account and all cloud data will be deleted forever.")
        }
        .alert("Data Archive Requested 📦", isPresented: $showExportConfirmationModal) {
            Button("Got it", role: .cancel) { }
        } message: {
            Text("Your archive is ready. Download it from Account Management when you are ready to share or save it. The link expires six hours after retrieval, or after 48 hours if untouched.")
        }
        .alert("Export Request Failed", isPresented: $showExportErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage ?? "Could not queue archive request. Please check your network connection.")
        }
        .sheet(isPresented: Binding(
            get: { downloadedArchiveURL != nil },
            set: { isPresented in
                if !isPresented { downloadedArchiveURL = nil }
            }
        )) {
            if let downloadedArchiveURL {
                ActivityView(activityItems: [downloadedArchiveURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            refreshLevel()
            DataExportService.shared.checkExportStatus { result in
                if case .success(let response) = result {
                    currentExportResponse = response
                }
            }
        }
        .trackScreen("AccountManagementView")
    }

    private func refreshLevel() {
        guard let summary = HomeDashboardRepository.shared.summary else { return }
        levelIndex = GamificationTrail.levelIndex(
            for: GamificationEngine.deriveSnapshot(facts: summary.toGamificationFacts())
        )
    }

    static func deletionErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain && nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
            return LocalizationHelper.localized("For your security, please sign out and sign back in, then try deleting your account again.")
        }
        return LocalizationHelper.localized("Couldn't delete your account. Check your connection and try again.")
    }
}
