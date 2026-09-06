import Foundation
import FirebaseFirestore

/// SCOPE_1.8.7 §6.3 — the fallback that makes "we told everyone" true.
///
/// The iOS twin of `data/remote/BroadcastReconciler.kt`.
///
/// Push is the fast path, not the only one, and it fails in ways nobody controls: the user declined
/// notifications, the device was off, APNs dropped it, the topic subscription had not completed, or
/// the payload arrived while the app was being force-quit. Any of those would otherwise mean a
/// rider never learns that the build they are running has a defect.
///
/// So every foreground also reads the collection. The store is idempotent by id, so a broadcast
/// that did arrive by push is not shown twice — and one that did not is picked up here silently,
/// without a second notification, because the moment to interrupt has passed.
///
/// Reads are unauthenticated by design: `firestore.rules` makes `broadcasts` world-readable and
/// nobody-writable. Requiring sign-in would silence exactly the local-only users this app is built
/// for, and the collection carries no personal data — it is addressed to everyone by definition.
enum BroadcastReconciler {

    /// Matches `BroadcastStore.maxRetained`: reading more than we would keep is wasted bandwidth.
    private static let limit = BroadcastStore.maxRetained

    /// - Returns: the number of broadcasts that were new to this device.
    @discardableResult
    @MainActor
    static func reconcile(store: BroadcastStore = .shared) async -> Int {
        do {
            let snapshot = try await Firestore.firestore()
                .collection("broadcasts")
                .order(by: "created_at_millis", descending: true)
                .limit(to: limit)
                .getDocuments()

            let versionCode = OperatorBroadcastReceiver.currentVersionCode()
            var stored = 0
            for document in snapshot.documents {
                // Parsed, not trusted. The rules make this collection unwritable by clients, but a
                // security rule protects the collection, not the shape of what is in it — the
                // parser is what enforces the closed tag vocabulary and the length limits.
                guard let broadcast = OperatorBroadcast.parse(document.data()),
                      broadcast.applies(toVersionCode: versionCode) else { continue }
                if store.store(broadcast) { stored += 1 }
            }
            return stored
        } catch {
            // Offline is the normal case for this app, not an error worth surfacing. The next
            // foreground retries and nothing is lost.
            CrashlyticsErrorLogger.shared.recordError(error)
            return 0
        }
    }
}
