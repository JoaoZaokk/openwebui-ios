import XCTest
@testable import OpenWebUIKit

/// Plain http:// — which addresses it is assumed for, which ones ask the person,
/// and what the request gate lets out. Reviews of 1.12 (Tailscale, "no internet"
/// with a server that Safari reaches) are the reason this exists.
final class CleartextTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testTailscaleAddressesAreLocalAndTypedBareGetHTTP() {
        // 100.64.0.0/10 is Tailscale's range; it used to fall through to https and
        // fail the TLS handshake against a plain-http server.
        XCTAssertTrue(OWConfig.isLocalHost("100.101.2.3"))
        XCTAssertTrue(OWConfig.isLocalHost("100.64.0.1"))
        XCTAssertTrue(OWConfig.isLocalHost("100.127.255.254"))
        XCTAssertFalse(OWConfig.isLocalHost("100.63.0.1"))
        XCTAssertFalse(OWConfig.isLocalHost("100.128.0.1"))
        XCTAssertEqual(OWConfig.normalize("100.101.2.3:3000")?.absoluteString, "http://100.101.2.3:3000")
        // A short MagicDNS / LAN name has no dot.
        XCTAssertEqual(OWConfig.normalize("meu-mac:8080")?.absoluteString, "http://meu-mac:8080")
        // Names with dots keep https by default; 10.evil.com is still not local.
        XCTAssertEqual(OWConfig.normalize("box.tail1234.ts.net")?.absoluteString, "https://box.tail1234.ts.net")
        XCTAssertFalse(OWConfig.isLocalHost("10.evil.com"))
    }

    func testClassification() {
        XCTAssertEqual(OWConfig.cleartext(url("https://a.example.com")), .none)
        XCTAssertEqual(OWConfig.cleartext(url("http://192.168.1.5:3000")), .local)
        XCTAssertEqual(OWConfig.cleartext(url("http://100.101.2.3:3000")), .local)
        XCTAssertEqual(OWConfig.cleartext(url("http://nas")), .local)
        XCTAssertEqual(OWConfig.cleartext(url("http://box.tail1234.ts.net:3000")), .tailnet)
        XCTAssertEqual(OWConfig.cleartext(url("http://openwebui.example.com")), .open)
        XCTAssertFalse(OWConfig.Cleartext.local.needsConsent)
        XCTAssertTrue(OWConfig.Cleartext.tailnet.needsConsent)
        XCTAssertTrue(OWConfig.Cleartext.open.needsConsent)
    }

    func testGateAllowsHTTPSLocalAndOnlyTheConfirmedServer() {
        let base = url("http://box.tail1234.ts.net:3000")
        let refused = OWConfig(baseURL: base)
        let allowed = OWConfig(baseURL: base, allowsCleartext: true)
        XCTAssertFalse(refused.permits(url("http://box.tail1234.ts.net:3000/api/config")))
        XCTAssertTrue(allowed.permits(url("http://box.tail1234.ts.net:3000/api/config")))
        // The confirmation is for that server, not for whatever a server names.
        XCTAssertFalse(allowed.permits(url("http://elsewhere.example.com/x.png")))
        XCTAssertFalse(allowed.permits(url("http://other.tail1234.ts.net/x")))
        XCTAssertTrue(allowed.permits(url("https://elsewhere.example.com/x.png")))
        XCTAssertTrue(refused.permits(url("http://192.168.1.5/x")))
    }

    func testNoConnectionOnTheInternetStaysNoConnection() {
        XCTAssertEqual(OWFailure.msg(URLError(.notConnectedToInternet)), L("Sem conexão com a internet."))
    }

    func testLocalNetworkProhibitedIsNamedAsWhatItIs() {
        let e = URLError(.notConnectedToInternet,
                         userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0"])
        XCTAssertTrue(e.isLocalNetworkProhibited)
        XCTAssertEqual(OWFailure.msg(e),
                       L("O iOS bloqueou o acesso à rede local. Em Ajustes › OpenWebUI, ligue Rede Local."))
        // Another failure that happens to carry a path description is not it.
        let other = URLError(.timedOut, userInfo: ["_NSURLErrorNWPathKey": "Local network prohibited"])
        XCTAssertFalse(other.isLocalNetworkProhibited)
    }

    func testTheClientRefusesCleartextToAnUnconfirmedServer() async {
        let client = OpenWebUIClient(config: OWConfig(baseURL: url("http://openwebui.example.com")))
        do {
            _ = try await client.serverConfig()
            XCTFail("should not have left the app")
        } catch {
            XCTAssertTrue(OWFailure.msg(error).contains("openwebui.example.com"), OWFailure.msg(error))
        }
    }
}
