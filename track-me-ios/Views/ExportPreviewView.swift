import SwiftUI
import MapKit

struct ExportPreviewView: View {
    let ride: Ride
    let snapshotImage: UIImage
    
    @State private var showTitle = true
    @State private var showDate = true
    @State private var showDuration = true
    @State private var showDistance = true
    @State private var privacyTrim = true
    @State private var darkOverlay = true
    @State private var selectedRatio: ExportRatio = .square
    @State private var renderedImage: UIImage
    @State private var isRendering = false
    @State private var ratioDebounce: DispatchWorkItem?
    
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isExportingVideo = false
    @State private var videoExportProgress: Float = 0
    @State private var videoExportTask: Task<Void, Never>?
    @ObservedObject private var unitSettings = UnitSettings.shared

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

    /// Pure seam shared by image and video export so the toggle cannot drift
    /// between the two presentation paths.
    static func renderPoints(_ points: [GPSPoint], privacyTrim: Bool, trimMeters: Double = 200.0) -> [GPSPoint] {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        return privacyTrim ? RoutePrivacyTrim.trim(sorted, trimMeters: trimMeters) : sorted
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
                Toggle(LocalizationHelper.localized("Privacy trim (200 m)"), isOn: $privacyTrim)
                Toggle(LocalizationHelper.localized("Dark overlay"), isOn: $darkOverlay)
            }
            .frame(height: 190)
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

            Button(action: exportVideo) {
                HStack {
                    if isExportingVideo {
                        ProgressView(value: videoExportProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 28)
                    } else {
                        Image(systemName: "video.fill")
                    }
                    Text(isExportingVideo
                         ? String(format: LocalizationHelper.localized("Exporting… %d%%"), Int(videoExportProgress * 100))
                         : LocalizationHelper.localized("Export video"))
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(hasEnoughPointsForVideo ? BrandColor.primaryFill : BrandColor.primaryFill.opacity(0.4))
                .cornerRadius(12)
            }
            .disabled(!hasEnoughPointsForVideo)
            .padding(.horizontal)
            if !hasEnoughPointsForVideo {
                Text(LocalizationHelper.localized("Not enough GPS points to export video"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            Spacer(minLength: 8)
        }
        .navigationTitle("Export Preview")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
        }
        .onChange(of: selectedRatio) { _, ratio in
            ratioDebounce?.cancel()
            let work = DispatchWorkItem { regenerateSnapshot(for: ratio) }
            ratioDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onChange(of: privacyTrim) { _, _ in
            ratioDebounce?.cancel()
            let work = DispatchWorkItem { regenerateSnapshot(for: selectedRatio) }
            ratioDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onAppear { regenerateSnapshot(for: selectedRatio) }
        .onDisappear { videoExportTask?.cancel() }
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    let aggregate = ride.aggregateSnapshot
                    let duration = Double(aggregate.movingDurationMillis) / 1_000
                    let dateStr = DateFormatter.localizedString(from: ride.startTime, dateStyle: .medium, timeStyle: .none)
                    let fields = [showDate ? dateStr : nil, showDuration ? String(format: "%02d:%02d:%02d", Int(duration) / 3600, (Int(duration) % 3600) / 60, Int(duration) % 60) : nil, showDistance ? UnitFormatter.distance(meters: aggregate.distanceMeters, unit: unitSettings.unit) : nil].compactMap { $0 }
                    if !fields.isEmpty {
                        Text(fields.joined(separator: " • "))
                            .font(.subheadline)
                            .foregroundColor(darkOverlay ? .white : .black)
                    }
                    HStack { Spacer(); Text("TrackMe") // TODO(attribution): replace with approved wordmark asset.
                        .font(.subheadline.weight(.semibold)).foregroundColor(darkOverlay ? .white : BrandColor.primary) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((darkOverlay ? Color.black : Color.white).opacity(darkOverlay ? 0.6 : 0.86))
        }
        .frame(width: 350, height: 350 / selectedRatio.aspect)
    }

    private func regenerateSnapshot(for ratio: ExportRatio) {
        isRendering = true
        let renderPoints = Self.renderPoints(ride.points ?? [], privacyTrim: privacyTrim)
        ImageExporter.generateSnapshot(points: renderPoints, size: ratio.snapshotSize) { image in
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

    private var hasEnoughPointsForVideo: Bool {
        (ride.points ?? []).count >= 2
    }

    @MainActor
    private func exportVideo() {
        if isExportingVideo {
            videoExportTask?.cancel()
            return
        }
        let untrimmed = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
        guard untrimmed.count >= 2 else { return }
        let width = 1080
        let height = max(1, Int((CGFloat(width) / selectedRatio.aspect).rounded()))
        let aggregate = ride.aggregateSnapshot
        let stats = ReplayStats(
            distanceMeters: aggregate.distanceMeters,
            durationMillis: aggregate.movingDurationMillis,
            averageSpeedMetersPerSecond: aggregate.avgSpeedMps
        )
        let overlay = ReplayOverlay(personaLabel: ride.ridePersona.displayName, imperialUnits: unitSettings.unit == .imperial)
        let config: ReplayExportConfig
        do {
            config = try ReplayExportConfig(width: width, height: height, applyPrivacyTrim: privacyTrim, persona: ride.ridePersona, overlay: overlay)
        } catch {
            ToastManager.shared.show(message: LocalizationHelper.localized("Couldn't create the video. Try again."), style: .error)
            return
        }
        let trimmed = Self.renderPoints(untrimmed, privacyTrim: config.applyPrivacyTrim, trimMeters: config.privacyTrimDistanceMeters)
        isExportingVideo = true
        videoExportProgress = 0
        videoExportTask = Task { @MainActor in
            let capture = await ReplayVideoExporter.captureRouteSnapshot(points: trimmed, size: CGSize(width: width / 2, height: height / 2))
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let url = try await ReplayVideoExporter.export(points: trimmed, stats: stats, config: config,
                    outputDirectory: directory, mapSnapshot: capture.0, routeProjection: capture.1) { progress in
                        Task { @MainActor in self.videoExportProgress = progress }
                    }
                try Task.checkCancellation()
                self.shareItems = [url]
                self.isShowingShareSheet = true
            } catch is CancellationError {
                // User dismissed the sheet or tapped the action while encoding.
            } catch ReplayVideoExporterError.cancelled {
                // Partial files are removed by the exporter.
            } catch {
                ToastManager.shared.show(message: LocalizationHelper.localized("Couldn't create the video. Try again."), style: .error)
            }
            self.isExportingVideo = false
            self.videoExportTask = nil
        }
    }
    
}
