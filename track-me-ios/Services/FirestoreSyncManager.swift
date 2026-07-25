import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseAuth

class FirestoreSyncManager {
    static let shared = FirestoreSyncManager()
    let db = Firestore.firestore()

    static let lastSyncTimestampKey = "last_sync_time"

    // MARK: - Sync Local -> Remote (Single Ride)
    func syncRide(_ ride: Ride, completion: ((Bool) -> Void)? = nil) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion?(false)
            return
        }

        let rideRef = db.collection("users").document(uid).collection("rides").document(ride.id.uuidString)

        let pointsArray = ride.points?.compactMap { point -> [String: Any]? in
            return [
                "lat": point.latitude,
                "lng": point.longitude,
                "altitude": point.altitude,
                "speed": point.speed,
                "timestamp": point.timestamp,
                "isPaused": point.isPaused
            ]
        } ?? []

        let data: [String: Any] = [
            "id": ride.id.uuidString,
            "startTime": ride.startTime,
            "endTime": ride.endTime ?? NSNull(),
            "sourceInfo": ride.sourceInfo,
            "title": ride.title ?? "",
            "persona": ride.persona,
            "points": pointsArray
        ]

        rideRef.setData(data, merge: true) { error in
            if error == nil {
                DispatchQueue.main.async {
                    ride.isSynced = true
                    ride.firestoreId = ride.id.uuidString
                    try? DataRepository.shared.container?.mainContext.save()
                    UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
                    completion?(true)
                }
            } else {
                completion?(false)
            }
        }
    }

    // MARK: - Download & Insert Helper
    private func downloadAndInsert(uid: String, limit: Int?, completion: @escaping (Bool) -> Void) {
        var ref: Query = db.collection("users").document(uid).collection("rides")
            .order(by: "startTime", descending: true)
        if let limit = limit {
            ref = ref.limit(to: limit)
        }
        ref.getDocuments { snapshot, error in
            guard let docs = snapshot?.documents, error == nil else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            let parsed = docs.compactMap { doc in
                FirestoreSyncManager.parseRideDocument(docId: doc.documentID, data: doc.data())
            }
            Task { @MainActor in
                let existingIds = DataRepository.shared.existingCloudIds()
                DataRepository.shared.importDownloadedRides(parsed, existingIds: existingIds)
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

        let group = DispatchGroup()
        var anyUploadFailed = false
        let lock = NSLock()

        for ride in unsynced {
            group.enter()
            syncRide(ride) { success in
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
                // 2. Download ALL cloud rides and insert the missing ones.
                self.downloadAndInsert(uid: uid, limit: nil) { success in
                    completion(success)
                }
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
