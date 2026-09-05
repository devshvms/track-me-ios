import Foundation
import SwiftData

/// Builds the app's `ModelContainer` — and never traps doing it.
///
/// ### Why this exists
///
/// Until 1.8.7 the container was built inline with `fatalError("Could not create ModelContainer")`
/// on failure, which was survivable only because the schema never changed in a way an existing
/// store could choke on. TASK-309 changed that: `EmergencyContact` and `EmergencySettings` were
/// deleted, so **every store written by 1.6.5–1.8.6 now opens against a model that no longer
/// describes two of its entities** and has to be migrated on first launch.
///
/// Removing an entity is a change SwiftData's inferred lightweight migration handles, and
/// `ModelContainerUpgradeTests` proves it against a real on-disk store written with the old
/// schema. That is good evidence. It is not a guarantee about every device, OS version and
/// half-written store in production — and the old code turned any such failure into an
/// unrecoverable launch crash, on upgrade, for exactly the riders whose leftover data the change
/// was meant to clear away. A crash loop is the worst possible outcome here: the user cannot open
/// the app, cannot export their rides, and cannot tell us anything.
///
/// So the ladder is:
///
/// 1. Open the store on disk. Effectively always this.
/// 2. If that throws, remember why and open an in-memory store so the app still launches.
///
/// Step 2 is a degraded state, not an acceptable one. The store file is left completely untouched
/// — nothing here deletes or recreates it — so the rides are still there and a later build can
/// still open them once we know from Crashlytics what went wrong. `AppDelegate` reports the
/// failure the moment Firebase is up, because an app that silently shows zero rides is worse than
/// one that says something is broken.
enum ModelContainerFactory {

    /// The current schema: ride history plus the Home dashboard index. Nothing else.
    static let schema = Schema([
        Ride.self,
        GPSPoint.self,
        HomeDashboardIndex.self
    ])

    static func make() -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            ModelContainerDiagnostics.shared.record(error)
            NSLog(
                "TrackMe: on-disk ModelContainer unavailable, falling back to memory: %@",
                String(describing: error)
            )
            return makeInMemory()
        }
    }

    /// Last resort. An in-memory container has no file to be incompatible with, so it cannot fail
    /// for any of the reasons the on-disk one can. If it fails anyway there is no app left to run.
    static func makeInMemory() -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        } catch {
            fatalError("Could not create an in-memory ModelContainer: \(error)")
        }
    }
}

/// Carries a store-open failure from launch — which happens before Firebase exists — to the first
/// moment something can report it.
final class ModelContainerDiagnostics: @unchecked Sendable {
    static let shared = ModelContainerDiagnostics()

    private let lock = NSLock()
    private var failure: Error?

    init() {}

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
    }

    /// Returns the failure once, then forgets it. Reporting the same launch failure on every
    /// foreground would say nothing new.
    func takeFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let taken = failure
        failure = nil
        return taken
    }
}
