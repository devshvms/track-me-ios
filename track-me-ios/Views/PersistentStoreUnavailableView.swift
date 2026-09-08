import SwiftUI

/// TASK-309 review fix — the persistent ride store could not be opened.
///
/// The factory deliberately preserves the original file and gives the process an in-memory
/// container so the app can render. That container is an emergency UI dependency, not a ride
/// store: anything written to it disappears at process exit. This root-level screen therefore
/// keeps every recording, import, sync and deletion path unreachable while still giving the rider
/// an honest explanation and a support route.
struct PersistentStoreUnavailableView: View {
    private var supportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = SupportContact.email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TrackMe iOS storage unavailable")
        ]
        return components.url
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    LocalizationHelper.localized("Ride storage is unavailable"),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
            } description: {
                Text(LocalizationHelper.localized(
                    "TrackMe could not safely open your saved rides. Recording is disabled so a new ride cannot be lost. Restart the app; if this continues, contact support."
                ))
            } actions: {
                if let supportURL {
                    Link(LocalizationHelper.localized("Contact support"), destination: supportURL)
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("TrackMe")
        }
    }
}
