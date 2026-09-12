import XCTest
@testable import track_me_ios

/// SCOPE_1.8.9 §11 gate 2 (parity), as something a machine can check — the twin of Android's
/// `TemplateLayoutVectorsTest`.
///
/// The gate asks that Android and iOS make the same layout decisions for the same template and ride,
/// expressed as frame fractions. A side-by-side screenshot proves that once, for the ride and the
/// moment it was taken. `template-layout-v1.json` proves it on every run for the decisions that are
/// actually shared: the design space, what each template declares, and where the route box sits in
/// its frame. The per-template type tables stay private to each renderer — the render tests cover
/// those — and this file covers the contract between the two.
final class TemplateLayoutVectorsTests: XCTestCase {

    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/template-layout-v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
            let alternative = directory.appendingPathComponent("track-me-iosTests/Resources/template-layout-v1.json")
            if FileManager.default.fileExists(atPath: alternative.path) { found = alternative; break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "template-layout-v1.json not found")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func canvas(_ name: String) throws -> TemplateCanvas {
        try XCTUnwrap(TemplateCanvas(rawValue: name), "unknown canvas: \(name)")
    }

    private func scope(_ name: String) throws -> TemplateScope {
        switch name {
        case "single": return .single
        case "aggregate": return .aggregate
        case "both": return .both
        default: throw XCTSkip("unknown scope: \(name)")
        }
    }

    func testTheDesignWidthIsTheOneBothRenderersScaleFrom() throws {
        XCTAssertEqual(try XCTUnwrap(vectors["design_width"] as? Double), Double(TemplateRenderer.designWidth))
    }

    func testEveryCanvasIsItsDestinationsRealSize() throws {
        let canvases = try XCTUnwrap(vectors["canvases"] as? [String: [String: Any]])
        for (name, want) in canvases {
            let spec = try canvas(name)
            XCTAssertEqual(spec.pixelSize.width, try XCTUnwrap(want["width"] as? Double), "\(name) width")
            XCTAssertEqual(spec.pixelSize.height, try XCTUnwrap(want["height"] as? Double), "\(name) height")
            XCTAssertEqual(Double(spec.aspect), try XCTUnwrap(want["aspect"] as? Double), accuracy: 1e-6, "\(name) aspect")
            XCTAssertEqual(spec.label, want["label"] as? String, "\(name) label")
        }
    }

    func testEveryTemplateDeclaresWhatTheContractSaysItDeclares() throws {
        let templates = try XCTUnwrap(vectors["templates"] as? [[String: Any]])
        XCTAssertEqual(templates.count, ExportTemplates.all.count, "template count")
        for (index, want) in templates.enumerated() where index < ExportTemplates.all.count {
            let id = try XCTUnwrap(want["id"] as? String)
            // Order matters: it is the strip's order, and a rider learns where the cards are.
            let spec = ExportTemplates.all[index]
            XCTAssertEqual(spec.id.analyticsValue, id, "declaration order at \(index)")
            XCTAssertEqual(spec.scope, try scope(try XCTUnwrap(want["scope"] as? String)), "\(id) scope")
            let canvases = try XCTUnwrap(want["canvases"] as? [String])
            XCTAssertEqual(spec.canvases.count, canvases.count, "\(id) canvas count")
            for (position, name) in canvases.enumerated() where position < spec.canvases.count {
                XCTAssertEqual(spec.canvases[position], try canvas(name), "\(id) canvas \(position)")
            }
            XCTAssertEqual(spec.defaultCanvas, try canvas(try XCTUnwrap(want["default_canvas"] as? String)), "\(id) default canvas")
            XCTAssertEqual(spec.transparent, want["transparent"] as? Bool, "\(id) transparent")
            XCTAssertEqual(spec.supportsMapBackground, want["supports_map_background"] as? Bool, "\(id) map background")
        }
    }

    func testTheTraceRouteBoxSitsWhereBothPlatformsPutIt() throws {
        let boxes = try XCTUnwrap(vectors["trace_route_box"] as? [String: [String: Double]])
        for (name, want) in boxes {
            let box = traceRouteBoxDesign(try canvas(name))
            XCTAssertEqual(Double(box.minX), try XCTUnwrap(want["left"]), accuracy: 1e-6, "\(name) left")
            XCTAssertEqual(Double(box.minY), try XCTUnwrap(want["top"]), accuracy: 1e-6, "\(name) top")
            XCTAssertEqual(Double(box.maxX), try XCTUnwrap(want["right"]), accuracy: 1e-6, "\(name) right")
            XCTAssertEqual(Double(box.maxY), try XCTUnwrap(want["bottom"]), accuracy: 1e-6, "\(name) bottom")
        }
    }

    /// The gate's own unit. A client that changed a canvas size without moving the box would keep the
    /// design-unit assertion above and fail here — which is the failure worth catching, because it is
    /// the one that silently reframes the route.
    func testTheRouteBoxIsTheSameFractionOfEveryFrameItIsDrawnIn() throws {
        let fractions = try XCTUnwrap(vectors["trace_route_box_fractions"] as? [String: Any])
        for (name, raw) in fractions where name != "_note" {
            let want = try XCTUnwrap(raw as? [String: Double])
            let spec = try canvas(name)
            let box = traceRouteBoxDesign(spec)
            let designHeight = TemplateRenderer.designWidth / spec.aspect
            XCTAssertEqual(Double(box.minX / TemplateRenderer.designWidth), try XCTUnwrap(want["left"]), accuracy: 1e-6, "\(name) left")
            XCTAssertEqual(Double(box.maxX / TemplateRenderer.designWidth), try XCTUnwrap(want["right"]), accuracy: 1e-6, "\(name) right")
            XCTAssertEqual(Double(box.minY / designHeight), try XCTUnwrap(want["top"]), accuracy: 1e-6, "\(name) top")
            XCTAssertEqual(Double(box.maxY / designHeight), try XCTUnwrap(want["bottom"]), accuracy: 1e-6, "\(name) bottom")
        }
    }
}
