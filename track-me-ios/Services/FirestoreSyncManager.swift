import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseAuth
import CryptoKit

enum RideDeletionOutcome: Equatable {
    case acknowledged
    case queued
}

enum RideDeletionFailureCause: String {
    case permission
    case network
    case unknown
}

enum RideCloudDeletionError: Error {
    case signInRequired
    case rejected(cause: RideDeletionFailureCause, chunkCount: Int, underlying: Error)
}

private actor RideOperationGate {
    private var active: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if active.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        guard let next = waiters[key]?.first else {
            active.remove(key)
            return
        }
        waiters[key]?.removeFirst()
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
        next.resume()
    }
}

private actor DownloadAccumulator {
    private var parsedById: [String: DownloadedRide] = [:]
    private var anyFailed = false

    func add(_ ride: DownloadedRide) {
        parsedById[ride.firestoreId] = ride
    }

    func markFailed() {
        anyFailed = true
    }

    func snapshot() -> (rides: [DownloadedRide], anyFailed: Bool) {
        (Array(parsedById.values), anyFailed)
    }
}

private let firestoreChunkIdentifierWidth = 6

private func firestoreChunkDocumentId(_ index: Int) -> String {
    String(format: "%0*d", firestoreChunkIdentifierWidth, max(0, index))
}

private func decodeFirestoreDouble(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

private func decodeFirestoreInt64(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}

private func decodeFirestoreDate(_ value: Any?) -> Date? {
    switch value {
    case let ts as Timestamp: return ts.dateValue()
    case let d as Date: return d
    case let n as NSNumber:
        let x = n.doubleValue
        return Date(timeIntervalSince1970: x >= 1_000_000_000_000 ? x / 1000.0 : x)
    default: return nil
    }
}

private func parseFirestorePoints(_ value: Any?) -> [DownloadedPoint] {
    let rawPoints = value as? [[String: Any]] ?? []
    return rawPoints.compactMap { p in
        guard let ts = decodeFirestoreDate(p["timestamp"]) else { return nil }
        return DownloadedPoint(
            latitude: decodeFirestoreDouble(p["lat"]) ?? 0,
            longitude: decodeFirestoreDouble(p["lng"]) ?? 0,
            altitude: decodeFirestoreDouble(p["altitude"]) ?? 0,
            accuracy: decodeFirestoreDouble(p["accuracy"]) ?? 0,
            speed: decodeFirestoreDouble(p["speed"]) ?? 0,
            timestamp: ts,
            isPaused: (p["isPaused"] as? Bool) ?? false
        )
    }
}

class FirestoreSyncManager {
    static let shared = FirestoreSyncManager()
    let db = Firestore.firestore()

    static let lastSyncTimestampKey = "last_sync_time"
    static let pointsPerChunk = 1_000
    private let rideOperationGate = RideOperationGate()

    // MARK: - Sync Local -> Remote (Chunked Ride)
    @discardableResult
    func uploadRide(_ ride: Ride) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        let rideRef = db.collection("users").document(uid).collection("rides").document(ride.id.uuidString)
        let key = rideRef.path
        await rideOperationGate.acquire(key)
        do {
            let result = try await uploadRideLocked(ride, rideRef: rideRef)
            await rideOperationGate.release(key)
            return result
        } catch {
            await rideOperationGate.release(key)
            return false
        }
    }

    private func uploadRideLocked(_ ride: Ride, rideRef: DocumentReference) async throws -> Bool {
        // A pending local tombstone wins over an upload. Without this guard a
        // queued delete could be resurrected by the next foreground sync (§2).
        guard !(await MainActor.run { ride.pendingDelete }) else { return false }

        let aggregate = ride.aggregateSnapshot
        let points = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
        let pointPayloads = points.map(Self.pointPayload)
        let chunks = stride(from: 0, to: pointPayloads.count, by: Self.pointsPerChunk).map { start in
            Array(pointPayloads[start ..< min(start + Self.pointsPerChunk, pointPayloads.count)])
        }
        let chunkCount = chunks.count
        let wallDurationMillis = ride.endTime.map {
            Int64(max(0, $0.timeIntervalSince(ride.startTime) * 1_000))
        } ?? aggregate.movingDurationMillis
        let pauseDurationMillis = max(0, wallDurationMillis - aggregate.movingDurationMillis)
        let parentData: [String: Any] = [
            "id": ride.id.uuidString,
            "startTime": ride.startTime,
            "endTime": ride.endTime ?? NSNull(),
            "sourceInfo": ride.sourceInfo,
            "title": ride.title ?? "",
            "persona": ride.persona,
            "maxSpeed": aggregate.maxSpeedMps,
            "distance": aggregate.distanceMeters,
            "avgSpeed": aggregate.avgSpeedMps,
            "pauseDuration": pauseDurationMillis,
            "movingDurationMillis": aggregate.movingDurationMillis,
            "pointCount": aggregate.pointCount,
            "chunkCount": chunkCount,
            "contentHash": Self.contentHash(points)
        ]

        // Children are committed before the parent. For the normal case this
        // is one atomic batch; longer rides use resumable child batches and a
        // final batch whose last operation is the parent commit marker (§2).
        try await commitChunksAndParent(
            chunks: chunks,
            parentData: parentData,
            rideRef: rideRef,
            ride: ride
        )

        // Overwriting a parent never removes a subcollection. Delete only
        // known surplus ids after the new parent is visible; readers already
        // ignore them through chunkCount (§2).
        let previousChunkCount = await MainActor.run { ride.cloudChunkCount }
        if let previousChunkCount, previousChunkCount > chunkCount {
            try await commitDeleteBatches(
                childRefs: (chunkCount ..< previousChunkCount).map {
                    rideRef.collection("points").document(Self.chunkDocumentId($0))
                },
                parentRef: nil
            )
        }

        await MainActor.run {
            ride.isSynced = true
            ride.firestoreId = ride.id.uuidString
            ride.cloudChunkCount = chunkCount
            try? DataRepository.shared.container?.mainContext.save()
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncTimestampKey)
        }
        return true
    }

    private func commitChunksAndParent(
        chunks: [[[String: Any]]],
        parentData: [String: Any],
        rideRef: DocumentReference,
        ride: Ride
    ) async throws {
        let maxChildrenWithParent = 499
        if chunks.isEmpty {
            let batch = db.batch()
            batch.setData(parentData, forDocument: rideRef)
            try await batch.commit()
            return
        }

        var next = 0
        while next < chunks.count {
            let remaining = chunks.count - next
            let count = min(remaining, maxChildrenWithParent)
            let batch = db.batch()
            for index in next ..< next + count {
                let chunkRef = rideRef.collection("points").document(Self.chunkDocumentId(index))
                batch.setData(["points": chunks[index]], forDocument: chunkRef)
            }
            let isFinalBatch = next + count == chunks.count
            if isFinalBatch {
                // Re-check immediately before the parent commit. The gate
                // serializes a concurrent delete; this check prevents a
                // pending tombstone from creating a new visible ride.
                guard !(await MainActor.run { ride.pendingDelete }) else { return }
                batch.setData(parentData, forDocument: rideRef)
            }
            try await batch.commit()
            next += count
            if !isFinalBatch {
                guard !(await MainActor.run { ride.pendingDelete }) else { return }
            }
        }
    }

    private static func pointPayload(_ point: GPSPoint) -> [String: Any] {
        [
            "lat": point.latitude,
            "lng": point.longitude,
            "altitude": point.altitude,
            "accuracy": point.accuracy,
            "speed": point.speed,
            "timestamp": point.timestamp,
            "isPaused": point.isPaused
        ]
    }

    static func chunkDocumentId(_ index: Int) -> String {
        firestoreChunkDocumentId(index)
    }

    private static func contentHash(_ points: [GPSPoint]) -> String {
        let canonical = points.sorted { $0.timestamp < $1.timestamp }.map {
            [
                String(format: "%.8f", $0.latitude),
                String(format: "%.8f", $0.longitude),
                String(format: "%.3f", $0.altitude),
                String(format: "%.3f", $0.accuracy),
                String(format: "%.3f", $0.speed),
                String(format: "%.6f", $0.timestamp.timeIntervalSince1970),
                $0.isPaused ? "1" : "0"
            ].joined(separator: ",")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func syncRide(_ ride: Ride, completion: ((Bool) -> Void)? = nil) {
        Task {
            let success = await uploadRide(ride)
            completion?(success)
        }
    }

    /// Returns the Firestore document that owns this local ride. Downloaded rides can have a
    /// document id that is unrelated to their local UUID, while older iOS uploads may be marked
    /// synced without having persisted `firestoreId` yet.
    static func cloudDocumentId(localId: UUID, firestoreId: String?, isSynced: Bool) -> String? {
        if let firestoreId = firestoreId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firestoreId.isEmpty {
            return firestoreId
        }
        return isSynced ? localId.uuidString : nil
    }

    /// A synced ride must be removed remotely before its local row is deleted. Otherwise the
    /// next sign-in download sees a missing local id and restores the supposedly deleted ride.
    func deleteRideFromCloudIfNeeded(_ ride: Ride) async throws -> RideDeletionOutcome {
        guard let documentId = Self.cloudDocumentId(
            localId: ride.id,
            firestoreId: ride.firestoreId,
            isSynced: ride.isSynced
        ) else { return .acknowledged }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw RideCloudDeletionError.signInRequired
        }

        guard await MainActor.run(body: {
            DataRepository.shared.markRidePendingDelete(rideId: ride.id)
        }) else { return .queued }

        // Offline is an honest queued state, not a rejection. The durable
        // local flag is retried on the next foreground/network opportunity.
        guard NetworkMonitor.shared.isConnected else { return .queued }

        let rideRef = db.collection("users").document(uid).collection("rides").document(documentId)
        let key = rideRef.path
        await rideOperationGate.acquire(key)
        var reportedChunkCount = await MainActor.run { ride.cloudChunkCount ?? 0 }
        do {
            reportedChunkCount = try await deleteCloudRide(
                rideRef: rideRef,
                fallbackChunkCount: reportedChunkCount
            )
            await rideOperationGate.release(key)
            return .acknowledged
        } catch {
            await rideOperationGate.release(key)
            let failure = RideCloudDeletionError.rejected(
                cause: Self.deletionFailureCause(error),
                chunkCount: reportedChunkCount,
                underlying: error
            )
            await MainActor.run {
                DataRepository.shared.restorePendingDelete(rideId: ride.id)
            }
            Self.reportDeletionFailure(failure, operation: "single")
            throw failure
        }
    }

    private func deleteCloudRide(
        rideRef: DocumentReference,
        fallbackChunkCount: Int
    ) async throws -> Int {
        let parent = try await rideRef.getDocument()
        let parentChunkCount = parent.data().flatMap { Self.decodeInt64($0["chunkCount"]) }
            .map { max(0, Int($0)) }
        let childSnapshot = try await rideRef.collection("points").getDocuments()
        let childRefs = childSnapshot.documents.map(\.reference)
        let knownChunkCount = parentChunkCount ?? (fallbackChunkCount > 0 ? fallbackChunkCount : childRefs.count)
        try await commitDeleteBatches(childRefs: childRefs, parentRef: rideRef)
        return knownChunkCount
    }

    private func commitDeleteBatches(
        childRefs: [DocumentReference],
        parentRef: DocumentReference?
    ) async throws {
        let maxChildrenPerBatch = parentRef == nil ? 500 : 499
        if childRefs.isEmpty {
            if let parentRef {
                let batch = db.batch()
                batch.deleteDocument(parentRef)
                try await batch.commit()
            }
            return
        }

        var next = 0
        while next < childRefs.count {
            let count = min(maxChildrenPerBatch, childRefs.count - next)
            let isFinal = next + count == childRefs.count
            let batch = db.batch()
            for ref in childRefs[next ..< next + count] {
                batch.deleteDocument(ref)
            }
            if isFinal, let parentRef {
                // The parent is the tombstone and is intentionally the last
                // operation in the final deletion batch (§2).
                batch.deleteDocument(parentRef)
            }
            try await batch.commit()
            next += count
        }
    }

    private static func deletionFailureCause(_ error: Error) -> RideDeletionFailureCause {
        if !NetworkMonitor.shared.isConnected { return .network }
        let code = (error as NSError).code
        return code == 7 ? .permission : .unknown
    }

    private static func reportDeletionFailure(_ error: RideCloudDeletionError, operation: String) {
        guard case let .rejected(cause, chunkCount, underlying) = error else { return }
        TelemetryManager.shared.trackRideDeleteFailed(cause: cause, operation: operation)
        CrashlyticsErrorLogger.shared.setCustomKey("ride_delete_operation", value: operation)
        CrashlyticsErrorLogger.shared.setCustomKey("ride_delete_chunk_count", value: String(chunkCount))
        CrashlyticsErrorLogger.shared.recordError(underlying)
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
        let accumulator = DownloadAccumulator()

        for query in queries {
            group.enter()
            query.getDocuments { snapshot, error in
                guard let docs = snapshot?.documents, error == nil else {
                    Task {
                        await accumulator.markFailed()
                        group.leave()
                    }
                    return
                }
                for doc in docs {
                    group.enter()
                    Task {
                        defer { group.leave() }
                        do {
                            guard let ride = try await self.parseCloudRide(doc) else { return }
                            await accumulator.add(ride)
                        } catch {
                            await accumulator.markFailed()
                        }
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            Task {
                let snapshot = await accumulator.snapshot()
                guard !snapshot.anyFailed else {
                    await MainActor.run { completion(false) }
                    return
                }
                let merged = snapshot.rides.sorted { $0.startTime > $1.startTime }
                await MainActor.run {
                    let existingIds = DataRepository.shared.existingCloudIds()
                    DataRepository.shared.importDownloadedRides(merged, existingIds: existingIds)
                    UserDefaults.standard.set(Date(), forKey: FirestoreSyncManager.lastSyncTimestampKey)
                    completion(true)
                }
            }
        }
    }

    /// Legacy parents keep their inline points array. New parents are commit
    /// markers, so a ride is imported only when all `chunkCount` children are
    /// present; a partial upload stays invisible rather than looking complete.
    private func parseCloudRide(_ doc: QueryDocumentSnapshot) async throws -> DownloadedRide? {
        let data = doc.data()
        guard let rawChunkCount = Self.decodeInt64(data["chunkCount"]) else {
            return Self.parseRideDocument(docId: doc.documentID, data: data)
        }
        let chunkCount = max(0, Int(rawChunkCount))
        guard chunkCount > 0 else {
            return Self.parseRideDocument(docId: doc.documentID, data: data, points: [], chunkCount: 0)
        }

        var orderedChunks = Array<Optional<[DownloadedPoint]>>(repeating: nil, count: chunkCount)
        try await withThrowingTaskGroup(of: (Int, [DownloadedPoint]?).self) { group in
            for index in 0 ..< chunkCount {
                group.addTask {
                    let chunkRef = doc.reference.collection("points")
                        .document(firestoreChunkDocumentId(index))
                    let snapshot = try await chunkRef.getDocument()
                    guard snapshot.exists else { return (index, nil) }
                    return (index, parseFirestorePoints(snapshot.data()?["points"]))
                }
            }
            for try await (index, points) in group {
                orderedChunks[index] = points
            }
        }

        guard orderedChunks.allSatisfy({ $0 != nil }) else { return nil }
        let points = orderedChunks.compactMap { $0 }.flatMap { $0 }
        return Self.parseRideDocument(
            docId: doc.documentID,
            data: data,
            points: points,
            chunkCount: chunkCount
        )
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
            self.processPendingDeletions()
            let localRides = DataRepository.shared.allRides()
            let unsynced = localRides.filter { !$0.isSynced && !$0.pendingDelete }

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
        let unsynced = localRides.filter { !$0.isSynced && !$0.pendingDelete }

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
        processPendingDeletions()
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
        processPendingDeletions()
        UserDefaults.standard.set(Date(), forKey: Self.foregroundThrottleKey)
        syncPeriodic { _ in }
    }

    /// Drains durable local tombstones after reconnect/launch. A queued delete
    /// is intentionally retried here instead of being treated as an error at
    /// the moment the user went offline (§2 offline deletion contract).
    func processPendingDeletions() {
        guard Auth.auth().currentUser != nil, NetworkMonitor.shared.isConnected else { return }
        Task { @MainActor in
            for ride in DataRepository.shared.pendingDeleteRides() {
                do {
                    let outcome = try await self.deleteRideFromCloudIfNeeded(ride)
                    if outcome == .acknowledged {
                        DataRepository.shared.deleteRide(rideId: ride.id)
                    }
                } catch is RideCloudDeletionError {
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("Couldn't delete this ride from the cloud. Check your connection and try again."),
                        style: .error
                    )
                } catch {
                    // The public deletion path normalizes cloud failures; this
                    // guard prevents a background retry from escaping its task.
                }
            }
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
            let chunks = try await doc.reference.collection("points").getDocuments()
            // Account deletion uses the same children-before-parent batches as
            // single-ride deletion; a parent-only delete would strand location
            // data in an unreachable subcollection (§2).
            try await commitDeleteBatches(
                childRefs: chunks.documents.map(\.reference),
                parentRef: doc.reference
            )
        }
        try await db.collection("users").document(uid).delete()
    }
}
