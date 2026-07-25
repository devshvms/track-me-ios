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
    @State private var selectedRatio: ExportRatio = .square
    @State private var renderedImage: UIImage
    @State private var isRendering = false
    
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []

    enum ExportRatio: String, CaseIterable, Identifiable {
        case square = "1:1", portrait = "4:5", story = "9:16"
        var id: String { rawValue }
        var aspect: CGFloat { switch self { case .square: return 1; case .portrait: return 4.0 / 5.0; case .story: return 9.0 / 16.0 } }
        var snapshotSize: CGSize { CGSize(width: 800, height: 800 / aspect) }
    }

    init(ride: Ride, snapshotImage: UIImage) {
        self.ride = ride
        self.snapshotImage = snapshotImage
        _renderedImage = State(initialValue: snapshotImage)
    }
    
    var body: some View {
        VStack {
            Spacer()
            exportFrame
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
                .shadow(radius: 10)
            Spacer()
            
            Form {
                Picker(LocalizationHelper.localized("Image ratio"), selection: $selectedRatio) {
                    ForEach(ExportRatio.allCases) { ratio in Text(ratio.rawValue).tag(ratio) }
                }.pickerStyle(.segmented)
                Toggle(LocalizationHelper.localized("Show ride title"), isOn: $showTitle)
                Toggle(LocalizationHelper.localized("Show date"), isOn: $showDate)
                Toggle(LocalizationHelper.localized("Show duration"), isOn: $showDuration)
                Toggle(LocalizationHelper.localized("Show distance"), isOn: $showDistance)
                Toggle(LocalizationHelper.localized("Dark overlay"), isOn: $darkOverlay)
            }
            .frame(height: 150)
            .cornerRadius(16)
            .padding(.horizontal)
            
            Button(action: shareImage) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text(LocalizationHelper.localized("Share image"))
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
        .onChange(of: selectedRatio) { _, ratio in regenerateSnapshot(for: ratio) }
    }
    
    var exportFrame: some View {
        ZStack(alignment: .bottom) {
            if isRendering { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Image(uiImage: renderedImage)
                .resizable()
                .scaledToFill()
                .aspectRatio(selectedRatio.aspect, contentMode: .fit)
                .clipped()
            
            VStack(alignment: .leading, spacing: 6) {
                    if showTitle {
                        Text(ride.title ?? LocalizationHelper.localized("TrackMe Ride"))
                            .font(.title2).bold()
                            .foregroundColor(darkOverlay ? .white : .black)
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
                    HStack { Spacer(); Text("TrackMe").font(.subheadline.weight(.semibold)).foregroundColor(darkOverlay ? .white : BrandColor.primary) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((darkOverlay ? Color.black : Color.white).opacity(darkOverlay ? 0.6 : 0.86))
        }
        .frame(width: 350, height: 350 / selectedRatio.aspect)
    }

    private func regenerateSnapshot(for ratio: ExportRatio) {
        isRendering = true
        ImageExporter.generateSnapshot(for: ride, size: ratio.snapshotSize) { image in
            Task { @MainActor in
                if let image { renderedImage = image }
                isRendering = false
            }
        }
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
