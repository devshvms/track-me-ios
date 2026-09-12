import SwiftUI
import MapKit

struct ExportPreviewView: View {
    let ride: Ride
    /// Only seeds the Custom tab's first frame; the view draws its own map on appear. Optional since
    /// 1.8.9: Templates need no map, so the sheet no longer waits for MapKit — offline included.
    let snapshotImage: UIImage?
    let demoMode: Bool
    let onDemoSave: (() -> Void)?
    
    @State private var showDate = true
    @State private var showDuration = true
    @State private var showDistance = true
    @State private var privacyTrim = true
    @State private var darkOverlay = true
    @State private var selectedRatio: ExportRatio = .square
    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var ratioDebounce: DispatchWorkItem?
    
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    /// Which artifact the open sheet is sharing, so the completion handler can name it.
    @State private var sharedArtifactKind: String?
    @State private var isExportingVideo = false
    @State private var videoExportProgress: Float = 0
    @State private var videoExportTask: Task<Void, Never>?
    @ObservedObject private var unitSettings = UnitSettings.shared
    /// SCOPE_1.8.9 §9 — Templates is the default tab; Custom is this view exactly as it was.
    @State private var mode: ExportMode = .templates

    enum ExportMode: Hashable { case templates, custom }

    enum ExportRatio: String, CaseIterable, Identifiable {
        case square = "1:1", portrait = "4:5", story = "9:16"
        var id: String { rawValue }
        var aspect: CGFloat { switch self { case .square: return 1; case .portrait: return 4.0 / 5.0; case .story: return 9.0 / 16.0 } }
        var snapshotSize: CGSize { CGSize(width: 800, height: 800 / aspect) }
    }

    init(
        ride: Ride,
        snapshotImage: UIImage?,
        demoMode: Bool = false,
        onDemoSave: (() -> Void)? = nil
    ) {
        self.ride = ride
        self.snapshotImage = snapshotImage
        self.demoMode = demoMode
        self.onDemoSave = onDemoSave
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
            if !demoMode {
                Picker("", selection: $mode) {
                    Text(LocalizationHelper.localized("Templates")).tag(ExportMode.templates)
                    Text(LocalizationHelper.localized("Custom")).tag(ExportMode.custom)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            // The onboarding demo exists to show one clean outcome, so it keeps the single Custom
            // surface it was built around; every real ride opens on Templates.
            if mode == .templates && !demoMode {
                TemplateExportPanel(ride: ride, ratio: $selectedRatio, privacyTrim: $privacyTrim) { url, template in
                    shareTemplate(url: url, template: template)
                }
            } else {
                customContent
            }
        }
        .navigationTitle(LocalizationHelper.localized("Export Preview"))
        .navigationBarTitleDisplayMode(.inline)
        // TASK-305: top of the export funnel. `.task` runs once per appearance, not per redraw —
        // a toggle flip is not a new export attempt, and counting it as one would make every
        // downstream ratio look worse than it is.
        .task { TelemetryManager.shared.trackExportPreviewOpened(surface: "ride_detail") }
        .onChange(of: showDate) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "figures") }
        .onChange(of: showDuration) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "figures") }
        .onChange(of: showDistance) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "figures") }
        .onChange(of: privacyTrim) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "privacy_trim") }
        .onChange(of: darkOverlay) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "theme") }
        .onChange(of: selectedRatio) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "ratio") }
        .onChange(of: mode) { _, _ in TelemetryManager.shared.trackExportStyleChanged(control: "mode") }
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            // ShareSheet rather than ActivityView: it is the one that reports completion, which is
            // what separates "shared" from "opened the sheet and backed out" (TASK-289).
            ShareSheet(
                activityItems: shareItems,
                onActivityCompletion: { activityType, completed, _ in
                    guard let kind = sharedArtifactKind else { return }
                    if activityType == .saveToCameraRoll {
                        TelemetryManager.shared.trackExportSavedToGallery(kind: kind, success: completed)
                    } else if completed {
                        TelemetryManager.shared.trackExportShared(kind: kind)
                    }
                }
            )
        }
        .onChange(of: selectedRatio) { _, ratio in
            guard !demoMode else { return }
            ratioDebounce?.cancel()
            let work = DispatchWorkItem { regenerateSnapshot(for: ratio) }
            ratioDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onChange(of: privacyTrim) { _, _ in
            guard !demoMode else { return }
            ratioDebounce?.cancel()
            let work = DispatchWorkItem { regenerateSnapshot(for: selectedRatio) }
            ratioDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onAppear {
            if !demoMode { regenerateSnapshot(for: selectedRatio) }
        }
        .onDisappear { videoExportTask?.cancel() }
    }
    
    /// Today's export, unchanged — the Custom tab (§9.1).
    @ViewBuilder
    private var customContent: some View {
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
                Toggle(LocalizationHelper.localized("Show date"), isOn: $showDate)
                Toggle(LocalizationHelper.localized("Show duration"), isOn: $showDuration)
                Toggle(LocalizationHelper.localized("Show distance"), isOn: $showDistance)
                if !demoMode {
                    Toggle(LocalizationHelper.localized("Privacy trim (200 m)"), isOn: $privacyTrim)
                }
                Toggle(LocalizationHelper.localized("Dark overlay"), isOn: $darkOverlay)
            }
            .frame(height: 190)
            .cornerRadius(16)
            .padding(.horizontal)
            
            Button {
                if demoMode {
                    saveDemo()
                } else {
                    shareImage()
                }
            } label: {
                HStack {
                    Image(systemName: demoMode ? "checkmark" : "square.and.arrow.up")
                    Text(LocalizationHelper.localized(demoMode ? "Save" : "Share image"))
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(renderedImage != nil ? BrandColor.primaryFill : BrandColor.primaryFill.opacity(0.4))
                .cornerRadius(12)
            }
            .disabled(renderedImage == nil)
            .padding(.horizontal)

            if !demoMode {
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
            }
            Spacer(minLength: 8)
    }

    var exportFrame: some View {
        ZStack(alignment: .bottom) {
            if isRendering { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(selectedRatio.aspect, contentMode: .fit)
                    .clipped()
            } else if !isRendering {
                // MapKit drew nothing (offline, or it refused). This tab has no picture without a
                // map, so it stays visibly empty and Share image stays off; Templates still work.
                Image(systemName: "map")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.secondarySystemBackground))
            }

            // Figures only — no ride title. It is a name the sharer already knows and the viewer
            // gets from the caption, and it cost a fifth of the frame to repeat. Android removed it
            // in 1.8.0 and shvm confirmed the same for iOS on 2026-08-22 (SCOPE_1.8.4 §8).
            //
            // This panel is rendered by `ImageRenderer(content: exportFrame)` in `shareImage()`, so
            // the preview and the file are literally the same view. That is why iOS never had
            // Android's drift defect, and it is worth preserving: do not add a second code path that
            // draws this panel for export.
            let aggregate = ride.aggregateSnapshot
            let duration = Double(aggregate.movingDurationMillis) / 1_000
            // TASK-241: formatted in the in-app language, not the device's.
            let dateStr = LocalizationHelper.mediumDateTime(ride.startTime, includeTime: false)
            // Compact, matching Android: "17min", never "00:17:00" — see `shareDuration`.
            // TASK-305: one builder, shared with the video. The two used to choose their
            // own figures *and* their own separator, which is the drift in miniature.
            let fields = overlayFigures(aggregate: aggregate, duration: duration, dateStr: dateStr)
            if !fields.isEmpty {
                Text(fields.joined(separator: ExportOverlayContent.separator))
                    .font(.subheadline)
                    .foregroundColor(darkOverlay ? .white : .black)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The panel hugs its figures. With every figure disabled there is no panel.
                    .background((darkOverlay ? Color.black : Color.white).opacity(darkOverlay ? 0.6 : 0.86))
            }

            // The preview must show what the file will contain, so this mirrors
            // `ReplayFrameRenderer` exactly: the link alone, small, bottom-right, no plate.
            //
            // The wordmark-and-link card that used to sit top-right is gone. A shared image of
            // someone's ride is theirs, and a branded box in the corner is the app signing their
            // photograph. The link survives because an artifact travels far from the app that made
            // it and a way back is a courtesy — the branding did not survive because it was not.
            //
            // Bottom-right, not bottom-left: the map's own Google attribution sits bottom-left and
            // is a required mark that must not be crowded.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(ReplayDeepLink.forRide(ride))
                        .font(.system(size: 8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundColor((darkOverlay ? Color.white : Color.black).opacity(0.8))
                        .shadow(color: .black.opacity(0.8), radius: 1.5)
                }
            }
            .padding(8)
        }
        .frame(width: 350, height: 350 / selectedRatio.aspect)
    }

    /// TASK-305: the figures both artifacts show, chosen once.
    ///
    /// A method rather than an inline expression because the video needs the identical list, and
    /// the video is a different renderer in a different file — the exact separation that let the
    /// two disagree in the first place.
    private func overlayFigures(
        aggregate: RideAggregateSnapshot,
        duration: Double,
        dateStr: String
    ) -> [String] {
        ExportOverlayContent.figures(
            date: dateStr,
            duration: UnitFormatter.shareDuration(seconds: duration),
            distance: UnitFormatter.distance(meters: aggregate.distanceMeters, unit: unitSettings.unit),
            showDate: showDate,
            showDuration: showDuration,
            showDistance: showDistance
        )
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
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let elapsedMillis = { Int64((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000) }
        if let uiImage = renderer.uiImage {
            TelemetryManager.shared.trackExportRendered(
                kind: "image", success: true, durationMillis: elapsedMillis()
            )
            shareItems = [uiImage]
            sharedArtifactKind = "image"
            TelemetryManager.shared.trackExportShareSheetOpened(kind: "image")
            isShowingShareSheet = true
        } else {
            // ImageRenderer returning nil is silent today: no toast, no log, nothing. It is the
            // one image-export failure mode we have never been able to see.
            TelemetryManager.shared.trackExportRendered(
                kind: "image",
                success: false,
                durationMillis: elapsedMillis(),
                failureReason: "image_renderer_nil"
            )
        }
    }

    /// SCOPE_1.8.9: a rendered template goes out as a PNG file — the format that keeps the Sticker's
    /// transparency through the share sheet and into Photos. The sheet itself is the one above, so a
    /// template share is counted by the same completion handler as every other export.
    @MainActor
    private func shareTemplate(url: URL, template: ExportTemplateID) {
        let kind = template == .sticker ? "sticker" : "image"
        shareItems = [url]
        sharedArtifactKind = kind
        TelemetryManager.shared.trackExportShareSheetOpened(kind: kind)
        isShowingShareSheet = true
    }

    @MainActor
    private func saveDemo() {
        onDemoSave?()
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
        // TASK-305: `persona.displayName` is the raw English enum name. Every other surface in the
        // app wraps it in LocalizationHelper — HomeView, HistoryView, HomeDashboardDeck all do —
        // and this was the one that did not, on the single artifact designed to leave the device.
        // A German user's shared video said "Cycling".
        let overlay = ReplayOverlay(
            personaLabel: LocalizationHelper.localized(ride.ridePersona.displayName),
            imperialUnits: unitSettings.unit == .imperial,
            figures: overlayFigures(
                aggregate: aggregate,
                duration: Double(aggregate.movingDurationMillis) / 1_000,
                dateStr: LocalizationHelper.mediumDateTime(ride.startTime, includeTime: false)
            ),
            darkTheme: darkOverlay
        )
        let config: ReplayExportConfig
        do {
            config = try ReplayExportConfig(
                width: width,
                height: height,
                applyPrivacyTrim: privacyTrim,
                persona: ride.ridePersona,
                deepLink: ReplayDeepLink.forRide(ride),
                overlay: overlay
            )
        } catch {
            ToastManager.shared.show(message: LocalizationHelper.localized("Couldn't create the video. Try again."), style: .error)
            return
        }
        let trimmed = Self.renderPoints(untrimmed, privacyTrim: config.applyPrivacyTrim, trimMeters: config.privacyTrimDistanceMeters)
        isExportingVideo = true
        videoExportProgress = 0
        let renderStartedAt = DispatchTime.now().uptimeNanoseconds
        let elapsedMillis = { Int64((DispatchTime.now().uptimeNanoseconds - renderStartedAt) / 1_000_000) }
        videoExportTask = Task { @MainActor in
            let capture = await ReplayVideoExporter.captureRouteSnapshot(points: trimmed, size: CGSize(width: width / 2, height: height / 2))
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let url = try await ReplayVideoExporter.export(points: trimmed, stats: stats, config: config,
                    outputDirectory: directory, mapSnapshot: capture.0, routeProjection: capture.1) { progress in
                        Task { @MainActor in self.videoExportProgress = progress }
                    }
                try Task.checkCancellation()
                TelemetryManager.shared.trackExportRendered(
                    kind: "video", success: true, durationMillis: elapsedMillis()
                )
                self.shareItems = [url]
                self.sharedArtifactKind = "video"
                TelemetryManager.shared.trackExportShareSheetOpened(kind: "video")
                self.isShowingShareSheet = true
            } catch is CancellationError {
                // User dismissed the sheet or tapped the action while encoding. A cancel is not a
                // failure: recording it as one would make the failure rate a measure of how often
                // people change their mind.
            } catch ReplayVideoExporterError.cancelled {
                // Partial files are removed by the exporter. Same reasoning as above.
            } catch {
                TelemetryManager.shared.trackExportRendered(
                    kind: "video",
                    success: false,
                    durationMillis: elapsedMillis(),
                    failureReason: String(describing: type(of: error))
                )
                ToastManager.shared.show(message: LocalizationHelper.localized("Couldn't create the video. Try again."), style: .error)
            }
            self.isExportingVideo = false
            self.videoExportTask = nil
        }
    }
    
}
