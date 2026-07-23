import XCTest
@testable import track_me_ios

final class LiveShareErrorTests: XCTestCase {
    func testUnauthorizedErrors() {
        let msg401 = LiveShareError.message(statusCode: 401, error: nil)
        let msg403 = LiveShareError.message(statusCode: 403, error: nil)
        
        let expected = LocalizationHelper.localized("Your sign-in expired. Please sign in again to share your location.")
        
        XCTAssertEqual(msg401, expected)
        XCTAssertEqual(msg403, expected)
    }
    
    func testUnavailableErrors() {
        let expected = LocalizationHelper.localized("Live sharing service is temporarily unavailable. Please try again later.")
        
        for code in [404, 500, 502, 503] {
            let msg = LiveShareError.message(statusCode: code, error: nil)
            XCTAssertEqual(msg, expected, "Failed for code \(code)")
        }
    }
    
    func testNetworkTimeoutErrors() {
        let expected = LocalizationHelper.localized("Connection timed out. Please check your internet connection and try again.")
        
        for code in [URLError.timedOut, URLError.networkConnectionLost] {
            let err = URLError(code)
            let msg = LiveShareError.message(statusCode: nil, error: err)
            XCTAssertEqual(msg, expected, "Failed for code \(code)")
        }
    }
    
    func testNetworkReachabilityErrors() {
        let expected = LocalizationHelper.localized("Unable to reach live share server. Please check your internet connection and try again.")
        
        for code in [URLError.notConnectedToInternet, URLError.cannotFindHost, URLError.cannotConnectToHost, URLError.dnsLookupFailed] {
            let err = URLError(code)
            let msg = LiveShareError.message(statusCode: nil, error: err)
            XCTAssertEqual(msg, expected, "Failed for code \(code)")
        }
    }
    
    func testSecureConnectionErrors() {
        let expected = LocalizationHelper.localized("Secure connection to live sharing server failed. Please try again.")
        
        for code in [URLError.secureConnectionFailed, URLError.serverCertificateUntrusted] {
            let err = URLError(code)
            let msg = LiveShareError.message(statusCode: nil, error: err)
            XCTAssertEqual(msg, expected, "Failed for code \(code)")
        }
    }
    
    func testGenericFallbackError() {
        let expected = LocalizationHelper.localized("Unable to connect to live share service. Please check your network connection.")
        let msg = LiveShareError.message(statusCode: nil, error: nil)
        XCTAssertEqual(msg, expected)
    }
}
