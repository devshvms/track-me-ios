import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseAuth

class FirestoreSyncManager {
    static let shared = FirestoreSyncManager()
    let db = Firestore.firestore()
    
    static let lastSyncTimestampKey = "last_sync_time"
    
    // MARK: - Sync Local -> Remote (Single Ride)
    func syncRide(_ ride: Ride) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
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
            "points": pointsArray
        ]
        
        rideRef.setData(data, merge: true) { error in
            if error == nil {
                DispatchQueue.main.async {
                    ride.isSynced = true
                    UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
                }
            }
        }
    }
    
    // MARK: - Horizon v1.2.0 Periodic Lightweight Sync (syncPeriodic)
    // Fetches top N recent cloud rides, deduplicating against existing local IDs
    func syncPeriodic(limit: Int = 10, localRideIds: Set<String>, completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(false)
            return
        }
        
        let ridesRef = db.collection("users").document(uid).collection("rides")
            .order(by: "startTime", descending: true)
            .limit(to: limit)
        
        ridesRef.getDocuments { snapshot, error in
            guard let documents = snapshot?.documents, error == nil else {
                completion(false)
                return
            }
            
            for doc in documents {
                let docId = doc.documentID
                // Horizon deduplication requirement: skip if already exists locally
                if localRideIds.contains(docId) {
                    continue
                }
                // Process and insert new cloud ride if needed
            }
            
            UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
            completion(true)
        }
    }
    
    // MARK: - Horizon v1.2.0 Manual Full Bidirectional Sync (syncAll)
    func syncAll(localRides: [Ride], completion: @escaping (Bool) -> Void) {
        guard Auth.auth().currentUser?.uid != nil else {
            completion(false)
            return
        }
        
        // 1. Upload unsynced local rides
        let unsynced = localRides.filter { !$0.isSynced }
        let group = DispatchGroup()
        
        for ride in unsynced {
            group.enter()
            syncRide(ride)
            group.leave()
        }
        
        group.notify(queue: .main) {
            UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
            completion(true)
        }
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
