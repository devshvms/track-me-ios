import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseAuth

class FirestoreSyncManager {
    static let shared = FirestoreSyncManager()
    let db = Firestore.firestore()

    static let lastSyncTimestampKey = "last_sync_time"

    // MARK: - Sync Local -> Remote (Single Ride)
    @discardableResult
    func uploadRide(_ ride: Ride) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        let rideRef = db.collection("users").document(uid).collection("rides").document(ride.id.uuidString)
        let aggregate = ride.aggregateSnapshot
        let pointsArray = ride.points?.map { point in
            ["lat": point.latitude, "lng": point.longitude, "altitude": point.altitude,
             "accuracy": point.accuracy, "speed": point.speed,
             "timestamp": point.timestamp, "isPaused": point.isPaused] as [String: Any]
        } ?? []
        let wallDurationMillis = ride.endTime.map {
            Int64(max(0, $0.timeIntervalSince(ride.startTime) * 1_000))
        } ?? aggregate.movingDurationMillis
        let pauseDurationMillis = max(0, wallDurationMillis - aggregate.movingDurationMillis)
        let data: [String: Any] = ["id": ride.id.uuidString, "startTime": ride.startTime,
            "endTime": ride.endTime ?? NSNull(), "sourceInfo": ride.sourceInfo,
            "title": ride.title ?? "", "persona": ride.persona,
            "maxSpeed": aggregate.maxSpeedMps, "distance": aggregate.distanceMeters,
            "avgSpeed": aggregate.avgSpeedMps, "pauseDuration": pauseDurationMillis,
            "movingDurationMillis": aggregate.movingDurationMillis,
            "pointCount": aggregate.pointCount, "points": pointsArray]
        do {
            try await rideRef.setData(data, merge: true)
            await MainActor.run {
                ride.isSynced = true
                ride.firestoreId = ride.id.uuidString
                try? DataRepository.shared.container?.mainContext.save()
                UserDefaults.standard.set(Date(), forKey: Self.lastSyncTimestampKey)
            }
            return true
        } catch {
            return false
        }
    }

    func syncRide(_ ride: Ride, completion: ((Bool) -> Void)? = nil) {
        Task {
            let success = await uploadRide(ride)
            completion?(success)
        }
    }

    /// Upper bound for a Number-typed `startTime`, used only to scope a range filter to the
    /// Number type group. ~year 2286 in epoch millis, so every real value sorts below it.
    private static let numericStartTimeCeiling: Int64 = 9_999_999_999_999

    // MARK: - Download & Insert Helper
    private func downloadAndInsert(uid: String, limit: Int?, completion: @escaping (Bool) -> Void) {
        let rides = db.collection("users").document(uid).collection("rides")

        guard let limit = limit else {
            // Full sync: one unfiltered pass already reaches every document regardless of type.
            runDownload(queries: [rides.order(by: "startTime", descending: true)], completion: completion)
            return
        }

        // `startTime` is mixed-type across platforms: iOS uploads a Date (Firestore Timestamp),
        // Android uploads a Long (Firestore Number). Firestore orders by value type before value,
        // so under `descending: true` every Timestamp sorts ahead of every Number — a plain
        // `.limit(to:)` fills the whole window with iOS-written rides and can never reach an
        // Android-written one. Range filters are scoped to a single type, so querying each type
        // group separately gets the newest `limit` from both; the results are merged below.
        let newestTimestampWritten = rides
            .whereField("startTime", isLessThan: Timestamp(date: .distantFuture))
            .order(by: "startTime", descending: true)
            .limit(to: limit)

        let newestNumberWritten = rides
            .whereField("startTime", isLessThan: FirestoreSyncManager.numericStartTimeCeiling)
            .order(by: "startTime", descending: true)
            .limit(to: limit)

        runDownload(queries: [newestTimestampWritten, newestNumberWritten], completion: completion)
    }

    /// Run every query, merge the parsed rides (deduped by document id), and import the union.
    /// Everything fetched is imported — trimming back to `limit` would pay for the reads and then
    /// throw the rides away, only to fetch them again on the next sync.
    private func runDownload(queries: [Query], completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var parsedById: [String: DownloadedRide] = [:]
        var anyFailed = false

        for query in queries {
            group.enter()
            query.getDocuments { snapshot, error in
                defer { group.leave() }
                guard let docs = snapshot?.documents, error == nil else {
                    lock.lock()
                    anyFailed = true
                    lock.unlock()
                    return
                }
                let parsed = docs.compactMap { doc in
                    FirestoreSyncManager.parseRideDocument(docId: doc.documentID, data: doc.data())
                }
                lock.lock()
                for ride in parsed { parsedById[ride.firestoreId] = ride }
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            if anyFailed {
                completion(false)
                return
            }
            let merged = parsedById.values.sorted { $0.startTime > $1.startTime }
            Task { @MainActor in
                let existingIds = DataRepository.shared.existingCloudIds()
                DataRepository.shared.importDownloadedRides(merged, existingIds: existingIds)
                UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
                completion(true)
            }
        }
    }

    // MARK: - Periodic Lightweight Sync (syncPeriodic)
    /// Bidirectional lightweight sync: upload unsynced local rides, then download the
    /// most-recent `limit` cloud rides and insert any not already present locally.
    /// Safe to call repeatedly; idempotent via firestoreId/id dedup.
    func syncPeriodic(limit: Int = 10, completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(false)
            return
        }

        Task { @MainActor in
            let localRides = DataRepository.shared.allRides()
            let unsynced = localRides.filter { !$0.isSynced }

            if unsynced.isEmpty {
                self.downloadAndInsert(uid: uid, limit: limit, completion: completion)
                return
            }

            let group = DispatchGroup()
            var anyUploadFailed = false
            let lock = NSLock()

            for ride in unsynced {
                group.enter()
                self.syncRide(ride) { success in
                    if !success {
                        lock.lock()
                        anyUploadFailed = true
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                if anyUploadFailed {
                    completion(false)
                } else {
                    self.downloadAndInsert(uid: uid, limit: limit, completion: completion)
                }
            }
        }
    }

    // MARK: - Manual Full Bidirectional Sync (syncAll)
    func syncAll(localRides: [Ride], completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(false)
            return
        }

        // 1. Upload unsynced local rides
        let unsynced = localRides.filter { !$0.isSynced }

        if unsynced.isEmpty {
            self.downloadAndInsert(uid: uid, limit: nil, completion: completion)
            return
        }

        Task {
            var failed = false
            await withTaskGroup(of: Bool.self) { group in
                for ride in unsynced {
                    group.addTask { await self.uploadRide(ride) }
                }
                for await success in group where !success { failed = true }
            }
            guard !failed else {
                await MainActor.run { completion(false) }
                return
            }
            self.downloadAndInsert(uid: uid, limit: nil) { success in
                completion(success)
            }
        }
    }

    // MARK: - Foreground & Auth Sync Triggers
    private static let foregroundThrottleKey = "last_periodic_sync_time"
    private static let foregroundThrottle: TimeInterval = 30 * 60   // 30 min

    /// Foreground/launch entry point: sync at most every 30 min, never while a ride
    /// is actively recording, only when signed in.
    func syncOnForegroundIfDue() {
        guard Auth.auth().currentUser != nil else { return }
        // Do NOT contend with live point writes.
        if TrackingManager.shared.state == .tracking || TrackingManager.shared.state == .paused { return }
        let last = UserDefaults.standard.object(forKey: Self.foregroundThrottleKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.foregroundThrottle { return }
        UserDefaults.standard.set(Date(), forKey: Self.foregroundThrottleKey)
        syncPeriodic { _ in }
    }

    /// Called right after a successful sign-in. Unlike syncOnForegroundIfDue this
    /// ignores the 30-min throttle (a sign-in is an explicit restore moment), but
    /// still refreshes the throttle timestamp so C.1 won't immediately re-fire.
    func syncOnSignInCompleted() {
        guard Auth.auth().currentUser != nil else { return }
        if TrackingManager.shared.state == .tracking || TrackingManager.shared.state == .paused { return }
        UserDefaults.standard.set(Date(), forKey: Self.foregroundThrottleKey)
        syncPeriodic { _ in }
    }


    // MARK: - Formatted Last Synced Timestamp
    static func formattedLastSyncTime() -> String {
        guard let lastSync = UserDefaults.standard.object(forKey: lastSyncTimestampKey) as? Date else {
            return LocalizationHelper.localized("Never")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: lastSync)
    }

    func deleteCloudData() async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ridesRef = db.collection("users").document(uid).collection("rides")
        let snapshot = try await ridesRef.getDocuments()
        for doc in snapshot.documents {
            try await doc.reference.delete()
        }
        try await db.collection("users").document(uid).delete()
    }
}
