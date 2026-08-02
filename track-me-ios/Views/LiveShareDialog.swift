import SwiftUI

struct LiveShareDialog: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var liveSharingManager = LiveSharingManager.shared
    enum SharingMode: String, CaseIterable, Identifiable {
        case timed = "Custom Duration"
        case rideLinked = "Until Ride Ends"
        var id: String { self.rawValue }
        var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }
    
    @State private var sharingMode: SharingMode = .timed
    @State private var hours: Int = 1
    @State private var minutes: Int = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if liveSharingManager.isActive {
                    activeSharingView
                } else {
                    inactiveSharingView
                }
            }
            .padding()
            .navigationTitle("Live Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    @ViewBuilder
    var inactiveSharingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(BrandColor.primary)
            
            Text("Share your live location with friends and family. Your location will be updated even if you haven't started recording a ride yet.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                Picker("Mode", selection: $sharingMode) {
                    ForEach(SharingMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                if sharingMode == .timed {
                    HStack {
                        Picker("Hours", selection: $hours) {
                            ForEach(0...23, id: \.self) { h in
                                Text(LocalizationHelper.formatted("%@ h", String(h))).tag(h)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        
                        Picker("Minutes", selection: $minutes) {
                            ForEach(0...59, id: \.self) { m in
                                Text(LocalizationHelper.formatted("%@ m", String(m))).tag(m)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                    }
                    .frame(height: 120)
                } else {
                    Text("Sharing will automatically stop when you finish your ride.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            
            Button(action: {
                if sharingMode == .timed {
                    let totalMinutes = (hours * 60) + minutes
                    liveSharingManager.startSession(durationMinutes: totalMinutes)
                } else {
                    liveSharingManager.startSession(durationMinutes: nil)
                }
            }) {
                Text("Start Sharing")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(BrandColor.primaryFill)
                    .cornerRadius(12)
            }
            .disabled(sharingMode == .timed && hours == 0 && minutes == 0)
        }
    }
    
    @ViewBuilder
    var activeSharingView: some View {
        VStack(spacing: 20) {
            
            VStack {
                Text(liveSharingManager.isRideLinked ? "Open Session" : "Expires in")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                LiveShareRemainingTimeView(
                    text: formatRemainingTime(liveSharingManager.remainingSeconds)
                )
            }
            
            if let link = liveSharingManager.shareLink {
                HStack {
                    Text(link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                    
                    Button(action: {
                        UIPasteboard.general.string = link
                        ToastManager.shared.show(message: LocalizationHelper.localized("Link copied to clipboard"), style: .success)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .padding()
                            .background(BrandColor.primary.opacity(0.1))
                            .foregroundColor(BrandColor.primary)
                            .cornerRadius(8)
                    }
                    
                    if let url = URL(string: link) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .padding()
                                .background(BrandColor.primary.opacity(0.1))
                                .foregroundColor(BrandColor.primary)
                                .cornerRadius(8)
                        }
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                liveSharingManager.stopSession()
            }) {
                Text("Stop Sharing")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(BrandColor.sos)
                    .cornerRadius(12)
            }
        }
    }
    
    private func formatRemainingTime(_ seconds: Int) -> String {
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

internal struct LiveShareRemainingTimeView: View {
    let text: String
    @ScaledMetric(relativeTo: .largeTitle) private var textSize: CGFloat = 40

    var body: some View {
        Text(text)
            .font(.system(size: textSize, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundColor(BrandColor.success)
    }
}
