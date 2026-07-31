import XCTest
@testable import track_me_ios

private enum RecordingError: Error, Equatable {
    case sample
}

private final class RecordingErrorLogger: ErrorLogger, @unchecked Sendable {
    private(set) var initialized = false
    private(set) var userIds: [String?] = []
    private(set) var customKeys: [(String, String)] = []
    private(set) var recordedErrors: [RecordingError] = []
    private(set) var loggedMessages: [String] = []

    func initialize() {
        initialized = true
    }

    func setUserId(_ userId: String?) {
        userIds.append(userId)
    }

    func setCustomKey(_ key: String, value: String) {
        customKeys.append((key, value))
    }

    func recordError(_ error: Error) {
        if let error = error as? RecordingError {
            recordedErrors.append(error)
        }
    }

    func log(_ message: String) {
        loggedMessages.append(message)
    }
}

final class CrashlyticsErrorLoggerTests: XCTestCase {
    func testRecordingLoggerCapturesTheSharedErrorContract() {
        let logger = RecordingErrorLogger()

        logger.initialize()
        logger.setUserId("user-123")
        logger.setUserId(nil)
        logger.setCustomKey("surface", value: "settings")
        logger.log("Anonymous sign in error")
        logger.recordError(RecordingError.sample)

        XCTAssertTrue(logger.initialized)
        XCTAssertEqual(logger.userIds.count, 2)
        XCTAssertEqual(logger.userIds[0]!, "user-123")
        XCTAssertNil(logger.userIds[1])
        XCTAssertEqual(logger.customKeys.map(\.0), ["surface"])
        XCTAssertEqual(logger.customKeys.map(\.1), ["settings"])
        XCTAssertEqual(logger.loggedMessages, ["Anonymous sign in error"])
        XCTAssertEqual(logger.recordedErrors, [.sample])
    }
}
