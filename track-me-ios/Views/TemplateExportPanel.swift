import SwiftUI
import UIKit

extension ExportPreviewView.ExportRatio {
    /// The Templates tab shares the ratio with Custom (§9.2): the same three ratios, one choice.
    var templateCanvas: TemplateCanvas {
        switch self {
        case .square: return .square
        case .portrait: return .portrait
        case .story: return .story
        }
    }

    init?(canvas: TemplateCanvas) {
        switch canvas {
        case .square: self = .square
        case .portrait: self = .portrait
        case .story: self = .story
        case .card: return nil
        }
    }
}

/// SCOPE_1.8.9 §9 — the Templates tab: the chosen design rendered for this ride by the same renderer
/// the export uses, a strip of real thumbnails of this ride in every design, and the chosen
/// template's options. Share renders the same function at the canvas's real width.
struct TemplateExportPanel: View {
    let ride: Ride
    @Binding var ratio: ExportPreviewView.ExportRatio
    @Binding var privacyTrim: Bool
    let onShare: (URL, ExportTemplateID) -> Void

    @ObservedObject private var unitSettings = UnitSettings.shared
    @State private var available: [ExportTemplateID] = []
    @State private var choice = ExportTemplateChoice()
    @State private var preview: UIImage?
    @State private var thumbnails: [ExportTemplateID: UIImage] = [:]
    /// Bumped when cached place names arrive, so every picture redraws with them.
    @State private var contentVersion = 0
    @State private var isExporting = false

    private var canvas: TemplateCanvas { ExportTemplates.canvas(for: choice.id, preferred: ratio.templateCanvas) }
    private var spec: ExportTemplateSpec { ExportTemplates.spec(choice.id) }

    private struct RenderKey: Equatable {
        let choice: ExportTemplateChoice
        let canvas: TemplateCanvas
        let privacyTrim: Bool
        let unit: String
        let version: Int
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
        .onAppear {
            available = ExportTemplateBuilder.available(for: ride, unit: unitSettings.unit)
            choice.id = TemplateMemory.recall(available: available)
        }
        .task(id: RenderKey(choice: choice, canvas: canvas, privacyTrim: privacyTrim, unit: "\(unitSettings.unit)", version: contentVersion)) {
            preview = await render(width: 720)
        }
        .task(id: RenderKey(choice: ExportTemplateChoice(place: choice.place), canvas: .story, privacyTrim: privacyTrim, unit: "\(unitSettings.unit)", version: contentVersion)) {
            var next: [ExportTemplateID: UIImage] = [:]
            for id in available {
                let thumbChoice = ExportTemplateChoice(id: id, place: choice.place)
                let content = ExportTemplateBuilder.build(ride: ride, choice: thumbChoice, privacyTrim: privacyTrim, unit: unitSettings.unit)
                next[id] = TemplateRenderer.render(id, canvas: ExportTemplates.spec(id).defaultCanvas, content: content, widthPx: 216)
            }
            thumbnails = next
        }
        .onChange(of: choice.place) { _, place in
            TelemetryManager.shared.trackExportStyleChanged(control: "place")
            guard place != .off, ride.placeLabelStart == nil, ride.placeLabelEnd == nil else { return }
            // Once, and only because the user asked (§7). A cached name is never looked up again.
            Task { @MainActor in
                let labels = await PlaceLabelResolver.resolve(ExportTemplateBuilder.sortedPoints(ride), geocode: PlaceLabelResolver.appleGeocoder)
                guard labels.start != nil || labels.end != nil else { return }
                DataRepository.shared.setPlaceLabels(rideId: ride.id, start: labels.start, end: labels.end)
                contentVersion += 1
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            if spec.transparent { Checkerboard().clipShape(RoundedRectangle(cornerRadius: 12)) }
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .aspectRatio(canvas.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: spec.transparent ? 0 : 8)
            } else {
                ProgressView()
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
                                if ExportTemplates.spec(id).transparent { Checkerboard() }
                                if let thumbnail = thumbnails[id] {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: ExportTemplates.spec(id).transparent ? .fit : .fill)
                                }
                            }
                            .frame(width: 72, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(id == choice.id ? BrandColor.primary : Color.secondary.opacity(0.35), lineWidth: id == choice.id ? 2 : 1))
                            // Two lines rather than an ellipsis: names are a fixed-width control, and the
                            // longest catalog value has to fit it (EXPORT_SHARE_CONTRACTS §3c).
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
                if spec.supportsMapBackground {
                    chip(LocalizationHelper.localized("Map background"), selected: choice.mapBackground) {
                        choice.mapBackground.toggle()
                        TelemetryManager.shared.trackExportStyleChanged(control: "map_background")
                    }
                }
                if choice.id == .hour {
                    // One tap to override the light: auto-picked colour charms when it matches the memory
                    // and irritates when it does not (§6.5).
                    chip(LocalizationHelper.localized("Auto"), selected: choice.lightOverride == nil) { setLight(nil) }
                    ForEach([LightPhase.dawn, .goldenMorning, .day, .dusk, .night], id: \.self) { phase in
                        chip(ExportTemplateBuilder.lightLabel(phase), selected: choice.lightOverride == phase) { setLight(phase) }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func setLight(_ phase: LightPhase?) {
        choice.lightOverride = phase
        TelemetryManager.shared.trackExportStyleChanged(control: "light")
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
        let content = ExportTemplateBuilder.build(ride: ride, choice: choice, privacyTrim: privacyTrim, unit: unitSettings.unit)
        var backdrop: MapBackdrop?
        if choice.mapBackground && choice.id == .trace {
            // A basemap that cannot be captured degrades to the plain ground — never to a route drawn
            // over a map it was not projected onto.
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
            // PNG, written to a file: the one format that keeps the Sticker transparent all the way to
            // the share sheet and into Photos.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrackMe_\(template.rawValue)_\(Int(Date().timeIntervalSince1970)).png")
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

/// Transparency made visible: the Sticker is a layer, and a layer on a flat colour hides that.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.11, green: 0.13, blue: 0.15)))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(red: 0.16, green: 0.19, blue: 0.22)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}
