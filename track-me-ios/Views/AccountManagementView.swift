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
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile Section
                VStack(spacing: 12) {
                    if let photoUrl = Auth.auth().currentUser?.photoURL {
                        AsyncImage(url: photoUrl) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 100, height: 100)
                            Image(systemName: "person.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                                .foregroundColor(.primary)
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
                
                // Emergency Setup Button
                NavigationLink(destination: EmergencySetupView()) {
                    Text("Configure Emergency Setup")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.primary)
                        .cornerRadius(24)
                }
                
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
                
                // Asynchronous Data Archive Export Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "archivebox.fill")
                            .foregroundColor(.blue)
                        Text("Data Archive & Export")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        if let status = currentExportResponse?.status {
                            Text(status)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(status == "COMPLETED" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                .foregroundColor(status == "COMPLETED" ? .green : .orange)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text("Request a comprehensive archive of your complete ride history (GPX files & JSON metadata). To protect server resources, data exports are paced during low-traffic off-peak windows (at most 1 export every 4 hours).")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    if currentExportResponse?.status == "COMPLETED", let downloadUrl = currentExportResponse?.downloadUrl, let url = URL(string: downloadUrl) {
                        Button(action: {
                            UIApplication.shared.open(url)
                        }) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download Archive (.zip)")
                                    .font(.subheadline).bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(24)
                        }
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
                            .background(Color.blue)
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
                            Text("Privacy Policy\n\nYour data is completely under your control. We only store data locally by default. If you enable Cloud Sync, your rides are securely stored on our servers. You can permanently delete your synced data or your entire account at any time using the options below. Deleted data cannot be recovered.")
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            Button(action: { showDeleteCloudWarning = true }) {
                                Text("Delete Cloud Data")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.clear)
                                    .foregroundColor(.red)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24)
                                            .stroke(Color.red.opacity(0.5), lineWidth: 1)
                                    )
                            }
                            
                            Button(action: { showDeleteAccountWarning = true }) {
                                Text("Delete Account & Data")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.red.opacity(0.15))
                                    .foregroundColor(.red)
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
                AuthManager.shared.signOut()
                dismiss()
            }
        } message: {
            Text("Signing out will clear all your synced rides from this phone's local history. They will remain safely in the cloud, and any new rides will be saved locally. Are you sure you want to sign out?")
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
                if confirmText == "DELETE" {
                    Task {
                        isDeleting = true
                        try? await AuthManager.shared.deleteAccountAndData(feedback: feedbackText)
                        isDeleting = false
                        dismiss()
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
            Text("Your request to download all historical rides (GPX traces & JSON archive) has been queued.\n\nOur servers process data archives asynchronously during low-traffic batch windows. Once ready, a secure 7-day download link will be emailed to your registered email address.")
        }
        .alert("Export Request Failed", isPresented: $showExportErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage ?? "Could not queue archive request. Please check your network connection.")
        }
        .onAppear {
            DataExportService.shared.checkExportStatus { result in
                if case .success(let response) = result {
                    currentExportResponse = response
                }
            }
        }
        .trackScreen("AccountManagementView")
    }
}
