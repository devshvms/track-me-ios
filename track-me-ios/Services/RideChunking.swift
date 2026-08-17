import Foundation

/// SCOPE_1.7.3 §2(a), §0 contracts 3–4, and §8 — the cross-platform ride
/// chunking wire contract.
///
/// Keep this contract executable on iOS. A client that formats `1` where the
/// other formats `001` uploads rides the other platform cannot find; this is
/// the kind of failure that stays invisible until someone changes phones.
enum RideChunkingContract {
    static let chunkSize = 1_000
    static let chunkIDDigits = 3
    static let deleteBatchLimit = 500
    static let chunkCountField = "chunkCount"
    static let chunkPointsField = "points"
    static let pointsSubcollection = "points"

    /// The reader and deleter construct ids from the committed chunk count,
    /// never from a sorted subcollection query (§2(a)). Past 999 the id grows
    /// to four digits by design; reassembly remains ordered by construction.
    static func chunkDocumentId(_ index: Int) -> String {
        precondition(index >= 0, "chunk index must not be negative, was \(index)")
        return String(format: "%0*d", chunkIDDigits, index)
    }

    /// Zero points is zero chunks, not one empty document. An empty child
    /// would always read as no ride data and creates an unnecessary orphan.
    static func chunkCount(for pointCount: Int) -> Int {
        precondition(pointCount >= 0, "point count must not be negative, was \(pointCount)")
        return (pointCount + chunkSize - 1) / chunkSize
    }

    static func chunkIds(for chunkCount: Int) -> [String] {
        precondition(chunkCount >= 0, "chunk count must not be negative, was \(chunkCount)")
        return (0..<chunkCount).map(chunkDocumentId)
    }

    static func partition<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: chunkSize).map { start in
            Array(values[start ..< min(start + chunkSize, values.count)])
        }
    }

    /// The parent joins the final delete batch when it fits under Firestore's
    /// 500-operation limit. Children are always deleted before the parent.
    static func deleteBatchCount(for chunkCount: Int) -> Int {
        precondition(chunkCount >= 0, "chunk count must not be negative, was \(chunkCount)")
        return max(1, (chunkCount + 1 + deleteBatchLimit - 1) / deleteBatchLimit)
    }

    static func deletesAtomically(chunkCount: Int) -> Bool {
        deleteBatchCount(for: chunkCount) == 1
    }
}
