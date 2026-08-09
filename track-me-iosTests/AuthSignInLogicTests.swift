import XCTest
import FirebaseAuth
import AuthenticationServices
import GoogleSignIn
@testable import track_me_ios

@MainActor
final class AuthSignInLogicTests: XCTestCase {
    func testCancellationPredicate_acceptsFirebaseCancellationCodes() {
        XCTAssertTrue(AuthManager.isSignInCancellation(AuthErrorCode.webContextCancelled))
    }

    func testCancellationPredicate_acceptsAuthenticationServicesCancellation() {
        let error = NSError(
            domain: "com.apple.AuthenticationServices.AuthorizationError",
            code: 1001
        )
        XCTAssertTrue(AuthManager.isSignInCancellation(error))
    }

    func testCancellationPredicate_acceptsGoogleCancellation() {
        let error = NSError(
            domain: kGIDSignInErrorDomain,
            code: -5
        )
        XCTAssertTrue(AuthManager.isSignInCancellation(error))
    }

    func testCancellationPredicate_rejectsNetworkAndUnknownErrors() {
        XCTAssertFalse(AuthManager.isSignInCancellation(AuthErrorCode.networkError))
        XCTAssertFalse(AuthManager.isSignInCancellation(NSError(domain: "Test", code: 42)))
    }

    func testErrorMessage_mapsNetworkFailure() {
        let message = AuthManager.signInErrorMessage(for: AuthErrorCode.networkError)
        XCTAssertEqual(message, "No connection — check your network and try again.")
    }

    func testErrorMessage_mapsUnknownFailureToNonEmptyGenericMessage() {
        let message = AuthManager.signInErrorMessage(for: NSError(domain: "Test", code: 42))
        XCTAssertEqual(message, "Sign-in isn't available right now. Please try again later.")
        XCTAssertFalse(message.isEmpty)
    }

    func testLinkPolicy_preservesAnonymousAccount() {
        XCTAssertEqual(SignInLinkPolicy.decide(isAnonymous: true), .link)
        XCTAssertEqual(SignInLinkPolicy.decide(isAnonymous: false), .signIn)
    }
}
