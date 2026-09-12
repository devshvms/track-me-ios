import SwiftUI
import UIKit

/// SCOPE_1.8.9 Part 2 — sharing a *selection* of rides as one picture.
///
/// Templates only, and deliberately: Android's aggregate surface grew out of its map compare screen,
/// which iOS has never had (§9.3 records that as a gap predating this scope). What Part 2 adds is a
/// template that needs no map at all, so the selection surface it needs is a list and a strip rather
/// than a second map screen — and building the map one to host it would be scope this release did
/// not ask for.
struct AggregateExportView: View {
    let rides: [Ride]
    let onDismiss: () -> Void

    @State private var ratio: ExportPreviewView.ExportRatio = .story
    @State private var privacyTrim = true
    @State private var shareItems: [Any] = []
    @State private var isShowingShareSheet = false
    @State private var sharedArtifactKind: String?

    var body: some View {
        NavigationStack {
            AggregateTemplatePanel(rides: rides, ratio: $ratio, privacyTrim: $privacyTrim) { url, template in
                sharedArtifactKind = template == .sticker ? "sticker" : "image"
                shareItems = [url]
                isShowingShareSheet = true
            }
            .navigationTitle(LocalizationHelper.localized("Aggregate rides"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationHelper.localized("Done"), action: onDismiss)
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .task { TelemetryManager.shared.trackExportPreviewOpened(surface: "multi_ride_compare") }
            .sheet(isPresented: $isShowingShareSheet) {
                // ShareSheet rather than ActivityView: it is the one that reports completion, which
                // is what separates "shared" from "opened the sheet and backed out" (TASK-289).
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
        }
    }
}

/// The aggregate twin of `TemplateExportPanel`: the chosen design rendered for *this selection* by
/// the same renderer the export uses, a strip of real thumbnails, and the chosen template's options.
struct AggregateTemplatePanel: View {
    let rides: [Ride]
    @Binding var ratio: ExportPreviewView.ExportRatio
    @Binding var privacyTrim: Bool
    let onShare: (URL, ExportTemplateID) -> Void

    @ObservedObject private var unitSettings = UnitSettings.shared
    @State private var choice = ExportTemplateChoice()
    @State private var preview: UIImage?
    @State private var thumbnails: [ExportTemplateID: UIImage] = [:]
    @State private var isExporting = false
    /// Nil until the place chip asks for names. Shape detection never waits on it — a rider offline
    /// is offered exactly the same strip, with unnamed stops (§7).
    @State private var placedLegs: [SelectionLeg]?
    @State private var isResolvingPlaces = false

    private var plainLegs: [SelectionLeg] { ExportTemplateAggregate.legs(rides) }
    private var legs: [SelectionLeg] { choice.place == .off ? plainLegs : (placedLegs ?? plainLegs) }
    private var available: [ExportTemplateID] { ExportTemplateAggregate.available(plainLegs) }
    private var canvas: TemplateCanvas { ExportTemplates.canvas(for: choice.id, preferred: ratio.templateCanvas) }
    private var spec: ExportTemplateSpec { ExportTemplates.spec(choice.id) }

    private struct RenderKey: Equatable {
        let choice: ExportTemplateChoice
        let canvas: TemplateCanvas
        let privacyTrim: Bool
        let unit: String
        let named: Bool
    }

    private var renderKey: RenderKey {
        RenderKey(choice: choice, canvas: canvas, privacyTrim: privacyTrim,
                  unit: "\(unitSettings.unit)", named: placedLegs != nil)
    }

    var body: some View {
        VStack(spacing: 10) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)
            strip
            options
            if choice.place != .off {
                Text(LocalizationHelper.localized("Place names are looked up once by your phone's map service, then kept on this device."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            shareButton
        }
        .padding(.bottom, 8)
        .onAppear { choice.id = TemplateMemory.recall(available: available) }
        // Choosing the Itinerary *is* the request for place names: it draws nothing else. Seen on
        // the simulator with names off, it is a rail of dots and distances that asserts no journey
        // at all. §7's rule is that a lookup happens only because the rider asked — and this is them
        // asking, whether they tapped the card now or chose it last time; the chip beside it still
        // turns names back off. Keyed on the id rather than written at the tap site because the
        // remembered choice arrives without a tap.
        .onChange(of: choice.id, initial: true) { _, id in
            if id == .itinerary && choice.place == .off { choice.place = .startAndFinish }
        }
        .task(id: renderKey) { preview = await render(width: 720) }
        .task(id: RenderKey(choice: ExportTemplateChoice(place: choice.place), canvas: .story,
                            privacyTrim: privacyTrim, unit: "\(unitSettings.unit)", named: placedLegs != nil)) {
            // One content for the whole strip: what a selection *says* does not depend on which
            // template is drawing it, unlike the single-ride panel where the choice carries the light.
            let content = ExportTemplateAggregate.build(rides: rides, legs: legs, privacyTrim: privacyTrim,
                                                        unit: unitSettings.unit,
                                                        dateLine: ExportTemplateAggregate.dateLine(startTimes: rides.map(\.startTime)))
            var next: [ExportTemplateID: UIImage] = [:]
            for id in available {
                next[id] = TemplateRenderer.render(id, canvas: ExportTemplates.spec(id).defaultCanvas, content: content, widthPx: 216)
            }
            thumbnails = next
        }
        .onChange(of: choice.place) { _, place in
            TelemetryManager.shared.trackExportStyleChanged(control: "place")
            // Once per selection. Two lookups per ride is already the most an aggregate may cost, and
            // repeating them on every chip tap would be the network cost the single-ride path was
            // careful to avoid.
            guard place != .off, placedLegs == nil, !isResolvingPlaces else { return }
            isResolvingPlaces = true
            Task { @MainActor in
                placedLegs = await ExportTemplateAggregate.legsWithPlaces(rides, geocode: PlaceLabelResolver.appleGeocoder)
                isResolvingPlaces = false
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .aspectRatio(canvas.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: spec.transparent ? 0 : 8)
            } else {
                ProgressView()
            }
            if isResolvingPlaces {
                VStack {
                    Spacer()
                    ProgressView().padding(8).background(.ultraThinMaterial).clipShape(Capsule()).padding(.bottom, 12)
                }
            }
        }
        .aspectRatio(canvas.aspect, contentMode: .fit)
    }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(available) { id in
                    Button {
                        guard id != choice.id else { return }
                        choice.id = id
                        TemplateMemory.remember(id)
                        TelemetryManager.shared.trackExportTemplateSelected(template: id.analyticsValue)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                if let thumbnail = thumbnails[id] {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: ExportTemplates.spec(id).transparent ? .fit : .fill)
                                }
                            }
                            .frame(width: 72, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(id == choice.id ? BrandColor.primary : Color.secondary.opacity(0.35),
                                        lineWidth: id == choice.id ? 2 : 1))
                            Text(ExportTemplateBuilder.templateName(id))
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundColor(id == choice.id ? BrandColor.primary : .secondary)
                                .frame(width: 84)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == choice.id ? [.isSelected] : [])
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Options

    private var options: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if spec.canvases.count > 1 {
                    ForEach(ExportTemplates.canvasChoices(for: choice.id), id: \.self) { option in
                        chip(option.label, selected: option == canvas) {
                            if let next = ExportPreviewView.ExportRatio(canvas: option) { ratio = next }
                            TelemetryManager.shared.trackExportStyleChanged(control: "ratio")
                        }
                    }
                }
                chip(LocalizationHelper.localized("Privacy trim (200 m)"), selected: privacyTrim) { privacyTrim.toggle() }
                ForEach(PlaceReference.allCases, id: \.self) { option in
                    chip(placeLabel(option), selected: choice.place == option) { choice.place = option }
                }
            }
            .padding(.horizontal)
        }
    }

    private func placeLabel(_ reference: PlaceReference) -> String {
        switch reference {
        case .off: return LocalizationHelper.localized("No place")
        case .startAndFinish: return LocalizationHelper.localized("Start & finish")
        case .finishOnly: return LocalizationHelper.localized("Finish only")
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? BrandColor.primary.opacity(0.18) : Color(UIColor.secondarySystemBackground))
                .overlay(Capsule().stroke(selected ? BrandColor.primary : Color.clear, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Share

    private var shareButton: some View {
        Button(action: share) {
            HStack {
                if isExporting { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
                Text(LocalizationHelper.localized("Share image"))
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(BrandColor.primaryFill)
            .cornerRadius(12)
        }
        .disabled(isExporting || preview == nil)
        .padding(.horizontal)
    }

    /// The preview and the file are one function at two widths — which is what keeps the preview honest.
    @MainActor
    private func render(width: CGFloat) async -> UIImage {
        let content = ExportTemplateAggregate.build(rides: rides, legs: legs, privacyTrim: privacyTrim,
                                                    unit: unitSettings.unit,
                                                    dateLine: ExportTemplateAggregate.dateLine(startTimes: rides.map(\.startTime)))
        var backdrop: MapBackdrop?
        if choice.mapBackground && choice.id == .trace {
            backdrop = await TemplateBackdrop.capture(content: content, canvas: canvas, widthPx: width)
        }
        return TemplateRenderer.render(choice.id, canvas: canvas, content: content, widthPx: width, backdrop: backdrop)
    }

    private func share() {
        let template = choice.id
        let kind = template == .sticker ? "sticker" : "image"
        isExporting = true
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let elapsed = { Int64((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000) }
        Task { @MainActor in
            defer { isExporting = false }
            let image = await render(width: canvas.pixelSize.width)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrackMe_selection_\(template.rawValue)_\(Int(Date().timeIntervalSince1970)).png")
            do {
                guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                TelemetryManager.shared.trackExportRendered(kind: kind, success: true, durationMillis: elapsed(), template: template.analyticsValue)
                onShare(url, template)
            } catch {
                TelemetryManager.shared.trackExportRendered(kind: kind, success: false, durationMillis: elapsed(),
                                                            failureReason: String(describing: type(of: error)), template: template.analyticsValue)
                ToastManager.shared.show(message: LocalizationHelper.localized("Couldn't create the image. Try again."), style: .error)
            }
        }
    }
}
