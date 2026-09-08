import XCTest
@testable import track_me_ios

/// TASK-305 — the still image and the replay video are made from one preview, and must agree.
///
/// `ExportPreviewView` carries a comment saying iOS "never had Android's drift defect", because
/// `shareImage()` renders `exportFrame` with `ImageRenderer` — the preview and the file really are
/// the same view. That is true, and worth preserving. It is also only about the **image**. The
/// video is a second renderer, in a different file, drawing its own text, and it had drifted in
/// four separate ways at once:
///
/// 1. It ignored `Show date`, `Show duration` and `Show distance` entirely.
/// 2. It ignored `Dark overlay`.
/// 3. It formatted the duration with `HistoryMetricFormat.duration` (`00:17:00`) where the image
///    used `UnitFormatter.shareDuration` (`17min`).
/// 4. It passed `RidePersona.displayName` — the raw English enum name — as the persona label, on
///    the one artifact designed to leave the device. Every other surface in the app wraps that in
///    `LocalizationHelper`.
final class ExportOverlayParityTests: XCTestCase {

    // MARK: - The shared builder

    func testEveryToggleOffProducesNothingRatherThanAnEmptyPanel() {
        let figures = ExportOverlayContent.figures(
            date: "Sep 06, 2026", duration: "17min", distance: "12.3 km",
            showDate: false, showDuration: false, showDistance: false
        )
        XCTAssertTrue(figures.isEmpty)
        XCTAssertFalse(ReplayOverlay(figures: figures).drawsPanel, "an empty panel is a box on bare map")
    }

    func testFiguresKeepDisplayOrderWhateverIsSwitchedOff() {
        // Date, then duration, then distance — the order is the contract, not an accident of how
        // the booleans happen to be written at either call site.
        XCTAssertEqual(
            ExportOverlayContent.figures(
                date: "D", duration: "T", distance: "X",
                showDate: true, showDuration: true, showDistance: true
            ),
            ["D", "T", "X"]
        )
        XCTAssertEqual(
            ExportOverlayContent.figures(
                date: "D", duration: "T", distance: "X",
                showDate: true, showDuration: false, showDistance: true
            ),
            ["D", "X"]
        )
        XCTAssertEqual(
            ExportOverlayContent.figures(
                date: "D", duration: "T", distance: "X",
                showDate: false, showDuration: true, showDistance: false
            ),
            ["T"]
        )
    }

    func testAllEightToggleCombinationsAreHonoured() {
        // Exhaustive, because the defect was not "one toggle was missed" — it was that the video
        // consulted none of them, which no single-case test distinguishes from a wiring slip.
        for date in [true, false] {
            for duration in [true, false] {
                for distance in [true, false] {
                    let figures = ExportOverlayContent.figures(
                        date: "D", duration: "T", distance: "X",
                        showDate: date, showDuration: duration, showDistance: distance
                    )
                    let expected = [date ? "D" : nil, duration ? "T" : nil, distance ? "X" : nil]
                        .compactMap { $0 }
                    XCTAssertEqual(figures, expected, "date=\(date) duration=\(duration) distance=\(distance)")
                }
            }
        }
    }

    func testBothRenderersJoinWithTheSameSeparator() {
        // They did not: the image joined with " • " and the video with " · ". The smallest possible
        // version of the drift, and the one most likely to come back.
        XCTAssertEqual(ExportOverlayContent.separator, " • ")
    }

    // MARK: - The overlay carried into the video

    func testTheDefaultOverlayDrawsNothingRatherThanSomethingWrong() {
        let overlay = ReplayOverlay()
        XCTAssertFalse(overlay.drawsPanel)
        XCTAssertTrue(overlay.darkTheme)
    }

    func testThemeReachesTheBurnedInChrome() {
        XCTAssertFalse(ReplayOverlay(darkTheme: false).darkTheme)
    }

    func testAnOverlayWithFiguresDrawsAPanel() {
        XCTAssertTrue(ReplayOverlay(figures: ["12.3 km"]).drawsPanel)
    }

    // MARK: - The link

    func testTheDeepLinkPrefixMatchesTheRouteTheWebsiteServes() {
        // This URL is burned into every frame of every exported video. It 404'd in production
        // until TASK-305 added the /r/ rewrite, so it is worth pinning the exact string rather
        // than trusting that two repositories stay in step by habit.
        XCTAssertEqual(ReplayDeepLink.prefix, "https://trackme.shvms.in/r/")
    }

    func testALocalRideStillGetsAWayBack() {
        // A ride that has never synced has no firestoreId. It still travels, so it still needs a
        // link — falling back to the local id rather than emitting no link at all.
        let ride = Ride(startTime: Date())
        let link = ReplayDeepLink.forRide(ride)
        XCTAssertTrue(link.hasPrefix(ReplayDeepLink.prefix))
        XCTAssertTrue(link.count > ReplayDeepLink.prefix.count, "the link must carry an identifier")
        XCTAssertTrue(ReplayDeepLink.isTrackMeLink(link))
    }

    func testAnEmptyCloudIdentifierFallsBackToTheLocalRide() {
        let ride = Ride(startTime: Date())
        ride.firestoreId = ""
        let link = ReplayDeepLink.forRide(ride)
        XCTAssertEqual(link, ReplayDeepLink.prefix + ride.id.uuidString)
    }

    func testOnlyOwnedNonEmptyLinksAreAcceptedForBurnIn() {
        XCTAssertTrue(ReplayDeepLink.isTrackMeLink(ReplayDeepLink.prefix + "ride-123"))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink(nil))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink(ReplayDeepLink.prefix))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink("https://example.com/r/ride-123"))
        XCTAssertFalse(ReplayDeepLink.isTrackMeLink(ReplayDeepLink.prefix + "ride 123"))
    }

    func testBothArtifactsCarryTheLinkEvenWhenThereIsNoFiguresPanel() {
        let previewSource = strippingComments(try! sourceFile("Views/ExportPreviewView.swift"))
        XCTAssertTrue(
            previewSource.contains("Text(ReplayDeepLink.forRide(ride))"),
            "the still image is rendered from exportFrame, so its link must live in that view"
        )
        XCTAssertTrue(
            previewSource.contains("deepLink: ReplayDeepLink.forRide(ride)"),
            "the replay renderer must receive the same public route"
        )

        let rendererSource = strippingComments(try! sourceFile("Services/ReplayFrameRenderer.swift"))
        let linkOffset = rendererSource.range(of: "ReplayDeepLink.isTrackMeLink")?.lowerBound
        let panelGuardOffset = rendererSource.range(of: "guard overlay.drawsPanel")?.lowerBound
        XCTAssertNotNil(linkOffset)
        XCTAssertNotNil(panelGuardOffset)
        if let linkOffset, let panelGuardOffset {
            XCTAssertLessThan(
                linkOffset,
                panelGuardOffset,
                "the mandatory lockup and link must render before no-panel mode returns"
            )
        }
    }

    // MARK: - The localisation bug, guarded at the source

    func testTheVideoLabelIsLocalisedLikeEveryOtherSurface() {
        // `RidePersona.displayName` is a raw English switch. Home, History and the dashboard deck
        // all wrap it in LocalizationHelper; the export video did not, so a German user's shared
        // video said "Cycling". Read from source because the failure is invisible in English —
        // which is the language it was written and reviewed in.
        let source = try! sourceFile("Views/ExportPreviewView.swift")
        let construction = source
            .components(separatedBy: "let overlay = ReplayOverlay(")
            .last ?? ""
        XCTAssertTrue(
            construction.contains("LocalizationHelper.localized(ride.ridePersona.displayName)"),
            "the exported video must not burn in the raw English persona name"
        )
        XCTAssertTrue(construction.contains("figures:"), "the video must receive the preview's figures")
        XCTAssertTrue(construction.contains("darkTheme:"), "the video must receive the theme choice")
    }

    func testTheVideoNoLongerDerivesItsOwnFigures() {
        // Comments are stripped first. Without that, the comment in `drawChrome` explaining which
        // formatters were removed re-failed this test by naming them — a source-reading assertion
        // that forbids documenting its own subject is worse than no assertion, because the cheapest
        // way to make it pass again is to delete the explanation.
        let source = strippingComments(try! sourceFile("Services/ReplayFrameRenderer.swift"))
        XCTAssertFalse(
            source.contains("HistoryMetricFormat.duration("),
            "the renderer must not format its own duration — that is how 00:17:00 met 17min"
        )
        XCTAssertFalse(
            source.contains("UnitFormatter.distance("),
            "the renderer must not format its own distance"
        )
        XCTAssertTrue(
            source.contains("overlay.figures.joined"),
            "the renderer must render the figures it was handed"
        )
    }

    private func strippingComments(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func sourceFile(_ relative: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // track-me-iosTests
            .deletingLastPathComponent()   // repo root
        for _ in 0..<4 {
            let candidate = directory.appendingPathComponent("track-me-ios/\(relative)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        XCTFail("could not locate \(relative)")
        return ""
    }
}
