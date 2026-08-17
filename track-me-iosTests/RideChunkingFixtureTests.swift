import Foundation
import XCTest
@testable import track_me_ios

/// The cross-platform chunking contract — SCOPE_1.7.3 §2(a), §0 contracts 3–4, and §8.
///
/// §8: do not let the two implementations agree only by inspection. A client
/// that formats `1` where the other formats `001` uploads rides the other
/// platform cannot find or reassemble; that failure waits until a user changes
/// phones. The fixture is copied byte-for-byte from track-me-web and is also
/// executed by Android.
final class RideChunkingFixtureTests: XCTestCase {
    func testLocalFixtureMatchesCanonicalCopyWhenAvailable() throws {
        let localURL = fixtureURL()
        guard let canonicalURL = findCanonicalFixture(from: localURL) else {
            throw XCTSkip("track-me-web is not checked out beside this repo; skipped byte-identity check")
        }
        XCTAssertEqual(
            try Data(contentsOf: canonicalURL),
            try Data(contentsOf: localURL),
            "The iOS fixture has drifted from the canonical web copy — §8 requires byte identity."
        )
    }

    func testShapeConstantsMatchTheContract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.shape.chunkSize, RideChunkingContract.chunkSize)
        XCTAssertEqual(fixture.shape.chunkIdDigits, RideChunkingContract.chunkIDDigits)
        XCTAssertEqual(fixture.shape.deleteBatchLimit, RideChunkingContract.deleteBatchLimit)
        XCTAssertEqual(fixture.shape.chunkCountField, RideChunkingContract.chunkCountField)
        XCTAssertEqual(fixture.shape.chunkPointsField, RideChunkingContract.chunkPointsField)
        XCTAssertEqual(fixture.shape.pointsSubcollection, RideChunkingContract.pointsSubcollection)
    }

    func testChunkIdVectorsMatchExactly() throws {
        let fixture = try loadFixture()
        for vector in fixture.chunkIds {
            XCTAssertEqual(
                RideChunkingContract.chunkDocumentId(vector.index),
                vector.id,
                vector.note ?? "chunk id for index \(vector.index)"
            )
        }
    }

    func testChunkCountVectorsMatchExactly() throws {
        let fixture = try loadFixture()
        for vector in fixture.chunkCounts {
            XCTAssertEqual(
                RideChunkingContract.chunkCount(for: vector.pointCount),
                vector.chunkCount,
                vector.note ?? "chunk count for \(vector.pointCount) points"
            )
        }
    }

    func testDeleteBatchingVectorsMatchExactly() throws {
        let fixture = try loadFixture()
        for vector in fixture.deleteBatching {
            XCTAssertEqual(
                RideChunkingContract.deleteBatchCount(for: vector.chunkCount),
                vector.batches,
                vector.note ?? "batch count for \(vector.chunkCount) chunks"
            )
            XCTAssertEqual(
                RideChunkingContract.deletesAtomically(chunkCount: vector.chunkCount),
                vector.atomic,
                vector.note ?? "atomicity for \(vector.chunkCount) chunks"
            )
        }
    }

    func testIdsAreLexicallyOrderedThroughTheThreeDigitRange() {
        let ids = RideChunkingContract.chunkIds(for: 1_000)
        XCTAssertEqual(ids, ids.sorted())
    }

    func testPartitioningCoversEveryPointExactlyOnceInOrder() {
        for count in [0, 1, 999, 1_000, 1_001, 2_500] {
            let points = Array(0..<count)
            let chunks = RideChunkingContract.partition(points)
            XCTAssertEqual(chunks.count, RideChunkingContract.chunkCount(for: count))
            XCTAssertEqual(chunks.flatMap { $0 }, points)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= RideChunkingContract.chunkSize })
        }
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ride-chunking-vectors.json")
    }

    private func loadFixture() throws -> RideChunkingFixture {
        try JSONDecoder().decode(RideChunkingFixture.self, from: Data(contentsOf: fixtureURL()))
    }

    private func findCanonicalFixture(from localURL: URL) -> URL? {
        var directory = localURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("track-me-web/tests/fixtures/ride-chunking-vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

private struct RideChunkingFixture: Decodable {
    let version: Int
    let shape: RideChunkingShape
    let chunkIds: [RideChunkIdVector]
    let chunkCounts: [RideChunkCountVector]
    let deleteBatching: [RideDeleteBatchVector]
}

private struct RideChunkingShape: Decodable {
    let chunkSize: Int
    let chunkIdDigits: Int
    let deleteBatchLimit: Int
    let chunkCountField: String
    let chunkPointsField: String
    let pointsSubcollection: String
}

private struct RideChunkIdVector: Decodable {
    let index: Int
    let id: String
    let note: String?
}

private struct RideChunkCountVector: Decodable {
    let pointCount: Int
    let chunkCount: Int
    let note: String?
}

private struct RideDeleteBatchVector: Decodable {
    let chunkCount: Int
    let batches: Int
    let atomic: Bool
    let note: String?
}
