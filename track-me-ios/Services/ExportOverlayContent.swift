import Foundation

/// TASK-305 — the one place that decides what a shared artifact says.
///
/// The iOS twin of Android's `buildOverlayContent`. It exists for the same reason that one does:
/// the still image and the replay video are made from a single preview, with a single set of
/// toggles, one button apart — and until 1.8.7 the video honoured none of them. It drew distance
/// and duration in a fixed treatment whatever the user had chosen, so turning off "Show distance"
/// produced an image without a distance and a video with one.
///
/// The image path itself was never at risk: `shareImage()` renders `exportFrame` with
/// `ImageRenderer`, so the preview and the file are literally the same view. That is a real
/// property worth preserving, and the comment in `ExportPreviewView` says so — but it describes the
/// image only, and it read as reassurance about the export surface as a whole. The video is a
/// second renderer, drawing its own text, and it had drifted exactly as the comment warned.
///
/// Takes already-formatted strings rather than a ride, so it stays pure, testable, and free of any
/// opinion about units, locale or date format. The *choice* of what appears, and in what order, is
/// made once, here.
enum ExportOverlayContent {

    /// The figures, in display order. Empty means there is nothing to draw — not an empty panel.
    static func figures(
        date: String,
        duration: String,
        distance: String,
        showDate: Bool,
        showDuration: Bool,
        showDistance: Bool
    ) -> [String] {
        var out: [String] = []
        if showDate { out.append(date) }
        if showDuration { out.append(duration) }
        if showDistance { out.append(distance) }
        return out
    }

    /// The separator both renderers join with. A constant because two renderers choosing their own
    /// is the smallest possible version of the drift this file exists to prevent — and it had
    /// already happened once: the image joined with " • " and the video with " · ".
    static let separator = " • "
}

/// The link burned into an exported artifact — the only route back from something that travels.
///
/// TASK-305 found this URL returning 404 in production: `vercel.json` had no `/r/` rewrite and the
/// Android manifest registers only `/g` as an app link, so the address on every replay video the
/// app had ever exported resolved nowhere. The route now lands on the landing page and records the
/// arrival as `utm_source: shared_artifact`, which is the other half of `export_shared` — sends at
/// one end, arrivals at the other.
enum ReplayDeepLink {
    static let prefix = "https://trackme.shvms.in/r/"

    /// Mirrors Android's `firestoreId.takeLast(12) ?: id`: the cloud id when the ride has synced,
    /// the local one otherwise. Neither is a secret and neither identifies a person; the id exists
    /// so a future shared-ride view has something to resolve, not so this link can be traced.
    static func forRide(_ ride: Ride) -> String {
        let cloudIdentifier = ride.firestoreId
            .map { String($0.suffix(12)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let identifier = cloudIdentifier ?? ride.id.uuidString
        return prefix + identifier
    }

    /// Only TrackMe-owned route URLs may be burned into a TrackMe-branded artifact.
    static func isTrackMeLink(_ value: String?) -> Bool {
        guard let value, value.hasPrefix(prefix) else { return false }
        let identifier = value.dropFirst(prefix.count)
        return !identifier.isEmpty && !identifier.contains(where: { $0.isWhitespace })
    }
}
