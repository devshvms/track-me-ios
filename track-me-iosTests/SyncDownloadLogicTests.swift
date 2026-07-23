import XCTest
import FirebaseFirestore
@testable import track_me_ios

final class SyncDownloadLogicTests: XCTestCase {

    func testDecodeDate() {
        // 1. Timestamp
        let ts = Timestamp(date: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(FirestoreSyncManager.decodeDate(ts), Date(timeIntervalSince1970: 1000))
        
        // 2. Epoch millis and seconds
        XCTAssertEqual(FirestoreSyncManager.decodeDate(NSNumber(value: 1_700_000_000_000)), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(FirestoreSyncManager.decodeDate(NSNumber(value: 1_700_000_000)), Date(timeIntervalSince1970: 1_700_000_000))
        
        // 3. Invalid
        XCTAssertNil(FirestoreSyncManager.decodeDate(NSNull()))
        XCTAssertNil(FirestoreSyncManager.decodeDate(nil))
        XCTAssertNil(FirestoreSyncManager.decodeDate("123"))
    }

    func testParseRideDocumentIOSShaped() {
        let uuid = UUID()
        let data: [String: Any] = [
            "id": uuid.uuidString,
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 100)),
            "sourceInfo": "iOS Device",
            "points": [
                [
                    "lat": 12.3,
                    "lng": 45.6,
                    "altitude": 78.9,
                    "speed": 1.2,
                    "timestamp": Timestamp(date: Date(timeIntervalSince1970: 101)),
                    "isPaused": false
                ]
            ]
        ]
        
        let ride = FirestoreSyncManager.parseRideDocument(docId: uuid.uuidString, data: data)
        XCTAssertNotNil(ride)
        XCTAssertEqual(ride?.localId, uuid)
        XCTAssertEqual(ride?.firestoreId, uuid.uuidString)
        XCTAssertEqual(ride?.startTime, Date(timeIntervalSince1970: 100))
        XCTAssertNil(ride?.endTime)
        XCTAssertEqual(ride?.sourceInfo, "iOS Device")
        XCTAssertEqual(ride?.points.count, 1)
        
        let point = ride!.points[0]
        XCTAssertEqual(point.latitude, 12.3)
        XCTAssertEqual(point.accuracy, 0) // default
        XCTAssertEqual(point.timestamp, Date(timeIntervalSince1970: 101))
    }

    func testParseRideDocumentAndroidShaped() {
        let docId = "android_doc_id"
        let data: [String: Any] = [
            "startTime": NSNumber(value: 1_700_000_000_000),
            "endTime": NSNumber(value: 1_700_000_005_000),
            "points": [
                [
                    "lat": 12.3,
                    "lng": 45.6,
                    "accuracy": 5.0,
                    "timestamp": NSNumber(value: 1_700_000_001_000)
                ]
            ]
        ]
        
        let ride = FirestoreSyncManager.parseRideDocument(docId: docId, data: data)
        XCTAssertNotNil(ride)
        XCTAssertEqual(ride?.firestoreId, docId)
        XCTAssertNotEqual(ride?.localId.uuidString, docId) // Fresh localId
        XCTAssertEqual(ride?.startTime, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ride?.endTime, Date(timeIntervalSince1970: 1_700_000_005))
        
        let point = ride!.points[0]
        XCTAssertEqual(point.accuracy, 5.0)
        XCTAssertEqual(point.timestamp, Date(timeIntervalSince1970: 1_700_000_001))
    }

    func testParseRideDocumentNoStartTime() {
        let data: [String: Any] = ["points": []]
        XCTAssertNil(FirestoreSyncManager.parseRideDocument(docId: "123", data: data))
    }

    func testParseRideDocumentNullEndTime() {
        let data: [String: Any] = [
            "startTime": Timestamp(date: Date()),
            "endTime": NSNull(),
            "points": []
        ]
        let ride = FirestoreSyncManager.parseRideDocument(docId: "123", data: data)
        XCTAssertNotNil(ride)
        XCTAssertNil(ride?.endTime)
    }

    func testMissingTimestampDropsPoint() {
        let data: [String: Any] = [
            "startTime": Timestamp(date: Date()),
            "points": [
                ["lat": 1.0], // missing timestamp
                ["lat": 2.0, "timestamp": Timestamp(date: Date())]
            ]
        ]
        let ride = FirestoreSyncManager.parseRideDocument(docId: "123", data: data)
        XCTAssertEqual(ride?.points.count, 1) // only 1 valid point
        XCTAssertEqual(ride?.points[0].latitude, 2.0)
    }
}
