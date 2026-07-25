import SwiftUI
import MapKit

struct ExportPreviewView: View {
    let ride: Ride
    let snapshotImage: UIImage
    
    @State private var showTitle = true
    @State private var showDate = true
    @State private var showDuration = true
    @State private var showDistance = true
    @State private var darkOverlay = true
    
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    
    var body: some View {
        VStack {
            Spacer()
            exportFrame
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
                .shadow(radius: 10)
            Spacer()
            
            Form {
                Toggle("Show Ride Title", isOn: $showTitle)
            Toggle("Show Date", isOn: $showDate)
            Toggle("Show Duration", isOn: $showDuration)
            Toggle("Show Distance", isOn: $showDistance)
            Toggle("Dark Overlay", isOn: $darkOverlay)
            }
            .frame(height: 150)
            .cornerRadius(16)
            .padding(.horizontal)
            
            Button(action: shareImage) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Image")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(BrandColor.primaryFill)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle("Export Preview")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
        }
    }
    
    var exportFrame: some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: snapshotImage)
                .resizable()
                .scaledToFill()
                .frame(width: 350, height: 400)
                .clipped()
            
            if showTitle || showDate || showDuration || showDistance {
                VStack(alignment: .leading, spacing: 6) {
                    if showTitle {
                        Text(ride.title ?? LocalizationHelper.localized("TrackMe Ride"))
                            .font(.title2).bold()
                            .foregroundColor(.white)
                    }
                    let points = ride.points ?? []
                    let duration = ride.endTime?.timeIntervalSince(ride.startTime) ?? points.last.map { $0.timestamp.timeIntervalSince(ride.startTime) } ?? 0
                    let dateStr = DateFormatter.localizedString(from: ride.startTime, dateStyle: .medium, timeStyle: .none)
                    let fields = [showDate ? dateStr : nil, showDuration ? String(format: "%02d:%02d:%02d", Int(duration) / 3600, (Int(duration) % 3600) / 60, Int(duration) % 60) : nil, showDistance ? String(format: "%.2f km", RideDistance.kilometers(points)) : nil].compactMap { $0 }
                    if !fields.isEmpty {
                        Text(fields.joined(separator: " • "))
                            .font(.subheadline)
                            .foregroundColor(darkOverlay ? .white : .black)
                    }
                    Text("TrackMe").font(.subheadline.weight(.semibold)).foregroundColor(darkOverlay ? .white : BrandColor.primary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((darkOverlay ? Color.black : Color.white).opacity(darkOverlay ? 0.6 : 0.86))
            }
        }
        .frame(width: 350, height: 400)
    }
    
    @MainActor
    private func shareImage() {
        let renderer = ImageRenderer(content: exportFrame)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            renderer.scale = windowScene.screen.scale
        } else {
            renderer.scale = 2.0
        }
        if let uiImage = renderer.uiImage {
            shareItems = [uiImage]
            isShowingShareSheet = true
        }
    }
    
}

struct StatBadge: View {
    var icon: String
    var value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value).bold()
        }
        .font(.caption)
        .foregroundColor(.white)
    }
}
