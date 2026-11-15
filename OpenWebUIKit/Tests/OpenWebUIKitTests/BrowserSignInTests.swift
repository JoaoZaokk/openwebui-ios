import XCTest
@testable import OpenWebUIKit

/// Signing in through the system browser (github.com/JoaoZaokk/openwebui-ios
/// issue #13: "It doesn't work with authentication using Passkeys (WebAuthn).
/// The problem is that you're using a web view instead of the default system
/// browser").
///
/// A web view has no passkeys and no password manager, so the page that does the
/// signing in has to run in the user's browser. Open WebUI 0.13 gives a native
/// client the way back: the app asks for a login request, opens
/// `/auth/sessions/{id}` in the browser, and the page ends by navigating to a
/// loopback URL the app is listening on (routers/sessions.py).
///
/// These tests pin the shapes the server's validators accept — a value the
/// server refuses fails with a 422 the user can do nothing about — and the
/// parsing of what comes back to the loopback listener.
final class BrowserSignInTests: XCTestCase {

    // MARK: - What the server's validators accept (sessions.py AuthorizationRequest)

    private func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// `state`: 32–256 characters of `[A-Za-z0-9_-]`. A 16-byte state — what
    /// `OWNativeOAuth.newState()` makes for Google — is 22 characters and would
    /// be refused, which is why this flow has a state of its own.
    func testAGeneratedStateFitsTheServersValidator() {
        for _ in 0..<50 {
            let s = OWBrowserSignIn.newState()
            XCTAssertTrue((32...256).contains(s.count), "length \(s.count)")
            XCTAssertTrue(matches("^[A-Za-z0-9_-]+$", s), s)
            XCTAssertTrue(OWBrowserSignIn.isValidState(s))
        }
        XCTAssertNotEqual(OWBrowserSignIn.newState(), OWBrowserSignIn.newState())
    }

    func testTheStateValidatorRefusesWhatTheServerWould() {
        XCTAssertFalse(OWBrowserSignIn.isValidState(String(repeating: "a", count: 31)))
        XCTAssertTrue(OWBrowserSignIn.isValidState(String(repeating: "a", count: 32)))
        XCTAssertTrue(OWBrowserSignIn.isValidState(String(repeating: "a", count: 256)))
        XCTAssertFalse(OWBrowserSignIn.isValidState(String(repeating: "a", count: 257)))
        XCTAssertFalse(OWBrowserSignIn.isValidState(String(repeating: "a", count: 31) + "="))
        XCTAssertFalse(OWBrowserSignIn.isValidState(String(repeating: "a", count: 31) + "+"))
    }

    /// `code_challenge` is exactly 43 base64url characters — the S256 of a
    /// 32-byte-derived verifier — and the verifier satisfies `code_verifier`'s
    /// own pattern at the exchange.
    func testThePKCEPairFitsBothValidators() {
        for _ in 0..<20 {
            let pkce = OWNativeOAuth.PKCE()
            XCTAssertEqual(pkce.challenge.count, 43)
            XCTAssertTrue(matches("^[A-Za-z0-9_-]{43}$", pkce.challenge))
            XCTAssertTrue((43...128).contains(pkce.verifier.count))
            XCTAssertTrue(matches("^[A-Za-z0-9._~-]+$", pkce.verifier))
        }
    }

    /// `redirect_uri`: http, host 127.0.0.1, a port, no userinfo/query/fragment.
    /// `localhost` is refused by the server, so is `::1`.
    func testTheRedirectURIIsTheLoopbackShapeTheServerRequires() throws {
        let uri = OWBrowserSignIn.redirectURI(port: 49152)
        XCTAssertEqual(uri, "http://127.0.0.1:49152/callback")
        let c = try XCTUnwrap(URLComponents(string: uri))
        XCTAssertEqual(c.scheme, "http")
        XCTAssertEqual(c.host, "127.0.0.1")
        XCTAssertEqual(c.port, 49152)
        XCTAssertNil(c.user); XCTAssertNil(c.password)
        XCTAssertNil(c.query); XCTAssertNil(c.fragment)
    }

    /// The request body names exactly the four fields the server declares, and no
    /// others: the model is `extra='forbid'`, so one stray key is a 422.
    func testTheRequestBodyCarriesExactlyTheFourFieldsTheServerDeclares() throws {
        let body = OWBrowserSignIn.RequestBody(
            name: "Open WebUI · iPhone", redirectURI: "http://127.0.0.1:5000/callback",
            state: String(repeating: "s", count: 40), codeChallenge: String(repeating: "c", count: 43))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["name", "redirect_uri", "state", "code_challenge"])
        XCTAssertEqual(json["redirect_uri"] as? String, "http://127.0.0.1:5000/callback")
    }

    func testTheExchangeBodyCarriesExactlyTheFieldsTheServerDeclares() throws {
        let body = OWBrowserSignIn.ExchangeBody(
            sessionID: "0b3a1c2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d", code: "jwt.code.here",
            codeVerifier: String(repeating: "v", count: 43), redirectURI: "http://127.0.0.1:5000/callback")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["session_id", "code", "code_verifier", "redirect_uri"])
    }

    /// The name is what the user sees in the list of their sessions on the web,
    /// and the server caps it at 100 characters.
    func testTheNameIsPrefixedAndNeverPastTheServersLimit() {
        XCTAssertEqual(OWBrowserSignIn.requestName(deviceLabel: "iPhone 15 Pro Max (iPhone16,2)"),
                       "Open WebUI · iPhone 15 Pro Max (iPhone16,2)")
        let long = OWBrowserSignIn.requestName(deviceLabel: String(repeating: "x", count: 400))
        XCTAssertEqual(long.count, 100)
        XCTAssertTrue(long.hasPrefix("Open WebUI · "))
        XCTAssertEqual(OWBrowserSignIn.requestName(deviceLabel: "  "), "Open WebUI")
    }

    // MARK: - The page the browser opens

    private let base = OWConfig(baseURL: URL(string: "https://chat.example.com")!)
    private let sid = "0b3a1c2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d"

    func testThePageURLWithoutAProviderIsJustTheSessionPage() {
        XCTAssertEqual(OWBrowserSignIn.pageURL(config: base, sessionID: sid, provider: nil).absoluteString,
                       "https://chat.example.com/auth/sessions/\(sid)")
        XCTAssertEqual(OWBrowserSignIn.pageURL(config: base, sessionID: sid, provider: "").absoluteString,
                       "https://chat.example.com/auth/sessions/\(sid)", "an empty key is no key")
    }

    func testTheProviderRidesAsAQueryValue() {
        XCTAssertEqual(OWBrowserSignIn.pageURL(config: base, sessionID: sid, provider: "microsoft").absoluteString,
                       "https://chat.example.com/auth/sessions/\(sid)?provider=microsoft")
    }

    /// A key is whatever the admin's config says; the page decodes it as one
    /// query value, so nothing in it may be read as another parameter.
    func testAProviderKeyIsPercentEncodedAsOneValue() {
        let url = OWBrowserSignIn.pageURL(config: base, sessionID: sid, provider: "a&b=c d+é")
        XCTAssertEqual(url.absoluteString,
                       "https://chat.example.com/auth/sessions/\(sid)?provider=a%26b%3Dc%20d%2B%C3%A9")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.value, "a&b=c d+é")
    }

    /// The session id is one path segment, whatever the server said it was.
    func testTheSessionIDIsOnePathSegment() {
        let url = OWBrowserSignIn.pageURL(config: base, sessionID: "../x?y#z", provider: nil)
        XCTAssertEqual(url.absoluteString, "https://chat.example.com/auth/sessions/..%2Fx%3Fy%23z")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    /// Only what the server issues — a UUID — is opened at all.
    func testOnlyAUUIDIsAcceptedAsASessionID() {
        XCTAssertTrue(OWBrowserSignIn.isValidSessionID(sid))
        XCTAssertTrue(OWBrowserSignIn.isValidSessionID(sid.uppercased()))
        XCTAssertFalse(OWBrowserSignIn.isValidSessionID(""))
        XCTAssertFalse(OWBrowserSignIn.isValidSessionID("../admin"))
        XCTAssertFalse(OWBrowserSignIn.isValidSessionID(sid + "?x=1"))
    }

    // MARK: - What the loopback listener hears

    private let state = String(repeating: "S", count: 43)

    private func outcome(_ line: String) -> OWLoopbackCallback.Outcome {
        OWLoopbackCallback.evaluate(requestLine: line, expectedState: state)
    }

    func testTheRedirectTheServersPageEndsWithIsTheCode() {
        XCTAssertEqual(outcome("GET /callback?code=abc.def.ghi&state=\(state) HTTP/1.1"),
                       .completed(code: "abc.def.ghi"))
    }

    /// The order of the parameters is the server's `urlencode` order, not a
    /// contract; the code is a JWT whose dots and dashes survive, and a
    /// percent-encoded one is decoded.
    func testParameterOrderAndPercentEncodingDoNotMatter() {
        XCTAssertEqual(outcome("GET /callback?state=\(state)&code=a%2Bb.c-d_e HTTP/1.1"),
                       .completed(code: "a+b.c-d_e"))
    }

    /// A reply whose state is not ours is not an answer to our request — a page
    /// in another tab can reach 127.0.0.1 too. It is refused and the wait goes
    /// on: it must not be able to end the user's sign-in.
    func testAWrongStateIsRefusedAndDoesNotEndTheWait() {
        let o = outcome("GET /callback?code=abc&state=\(String(repeating: "X", count: 43)) HTTP/1.1")
        XCTAssertEqual(o, .badState)
        XCTAssertFalse(o.isTerminal)
        XCTAssertEqual(outcome("GET /callback?code=abc HTTP/1.1"), .badState, "no state at all is no state")
    }

    /// The state is checked before anything else is read, errors included.
    func testAnErrorWithoutOurStateCannotCancelTheSignIn() {
        let o = outcome("GET /callback?error=access_denied HTTP/1.1")
        XCTAssertEqual(o, .badState)
        XCTAssertFalse(o.isTerminal)
    }

    func testMissingCodeWithTheRightStateIsATerminalFailure() {
        let o = outcome("GET /callback?state=\(state) HTTP/1.1")
        XCTAssertEqual(o, .missingCode)
        XCTAssertTrue(o.isTerminal)
        XCTAssertEqual(outcome("GET /callback?state=\(state)&code= HTTP/1.1"), .missingCode)
    }

    func testAnErrorParameterWithTheRightStateIsTheFailureTheServerNamed() {
        let o = outcome("GET /callback?state=\(state)&error=access_denied&error_description=Nope HTTP/1.1")
        XCTAssertEqual(o, .failed("Nope"))
        XCTAssertTrue(o.isTerminal)
        XCTAssertEqual(outcome("GET /callback?state=\(state)&error=access_denied HTTP/1.1"), .failed("access_denied"))
    }

    /// The browser asks for the favicon right after; that and everything else is
    /// a 404 that changes nothing.
    func testEveryOtherPathIsNotFoundAndKeepsListening() {
        for line in ["GET /favicon.ico HTTP/1.1", "GET / HTTP/1.1", "GET /callback/ HTTP/1.1",
                     "GET /callback/x?code=a&state=\(state) HTTP/1.1", "GET /CALLBACK?code=a&state=\(state) HTTP/1.1"] {
            let o = outcome(line)
            XCTAssertEqual(o, .notFound, line)
            XCTAssertFalse(o.isTerminal, line)
        }
    }

    func testOnlyGETIsAnswered() {
        XCTAssertEqual(outcome("POST /callback?code=a&state=\(state) HTTP/1.1"), .notFound)
        XCTAssertEqual(outcome("HEAD /callback?code=a&state=\(state) HTTP/1.1"), .notFound)
    }

    func testGarbageIsMalformedAndKeepsListening() {
        for line in ["", "GET", "\u{0}\u{1}\u{2}", "GET callback HTTP/1.1", "GET http://evil.example/callback?code=a&state=x HTTP/1.1"] {
            let o = outcome(line)
            XCTAssertFalse(o.isTerminal, line)
        }
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(OWLoopbackCallback.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(OWLoopbackCallback.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(OWLoopbackCallback.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(OWLoopbackCallback.constantTimeEquals("", "a"))
        XCTAssertTrue(OWLoopbackCallback.constantTimeEquals("", ""))
    }

    // MARK: - Reading the request off the socket

    func testTheRequestLineIsReadOnceItsLineEndHasArrived() {
        XCTAssertNil(OWLoopbackCallback.requestLine(in: Data("GET /callback?co".utf8)))
        XCTAssertEqual(OWLoopbackCallback.requestLine(in: Data("GET /a HTTP/1.1\r\nHost: x\r\n\r\n".utf8)),
                       "GET /a HTTP/1.1")
        XCTAssertEqual(OWLoopbackCallback.requestLine(in: Data("GET /a HTTP/1.1\nHost: x\n".utf8)),
                       "GET /a HTTP/1.1")
    }

    /// A peer that never sends a line end must not make the app buffer forever.
    func testAnOverlongRequestLineIsGivenUpOn() {
        let huge = Data(repeating: UInt8(ascii: "a"), count: OWLoopbackCallback.maxRequestLine + 1)
        XCTAssertEqual(OWLoopbackCallback.requestLine(in: huge), "")
    }

    // MARK: - What it answers

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testTheSuccessPageIsASmallHTMLDocumentThatIsNeverCachedOrLeaked() {
        let raw = text(OWLoopbackCallback.response(for: .completed(code: "x")))
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(raw.contains("Content-Type: text/html; charset=utf-8\r\n"))
        XCTAssertTrue(raw.contains("Cache-Control: no-store\r\n"))
        // The browser landed here with a login code in the address; nothing on
        // this page may carry it anywhere.
        XCTAssertTrue(raw.contains("Referrer-Policy: no-referrer\r\n"))
        XCTAssertTrue(raw.contains("Connection: close\r\n"))
        XCTAssertFalse(raw.contains("<script"))
        XCTAssertFalse(raw.contains("http://"))
        XCTAssertFalse(raw.contains("https://"))
    }

    func testTheContentLengthIsTheBodysByteCount() throws {
        let data = OWLoopbackCallback.response(for: .failed("x"))
        let raw = text(data)
        let split = try XCTUnwrap(raw.range(of: "\r\n\r\n"))
        let body = Data(raw[split.upperBound...].utf8)
        let header = raw[..<split.lowerBound]
        let length = try XCTUnwrap(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length:") })
        XCTAssertEqual(length, "Content-Length: \(body.count)")
    }

    func testStatusesFollowTheOutcome() {
        XCTAssertTrue(text(OWLoopbackCallback.response(for: .notFound)).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text(OWLoopbackCallback.response(for: .badState)).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(text(OWLoopbackCallback.response(for: .malformed)).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(text(OWLoopbackCallback.response(for: .missingCode)).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    /// The server's sentence is shown on a page in the user's browser; it is
    /// text, never markup.
    func testAFailureSentenceIsEscapedIntoThePage() {
        let raw = text(OWLoopbackCallback.response(for: .failed("<script>alert(1)</script> & \"q\"")))
        XCTAssertFalse(raw.contains("<script>"))
        XCTAssertTrue(raw.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;"))
    }
}
