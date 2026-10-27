import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// App Review, 1.11 on iPad: signed in, "Couldn't find that server". The
/// Keychain outlives a deleted app and UserDefaults does not, so a reinstall
/// found the old token with no server saved, skipped the login and talked to
/// the placeholder host. A token with no server belongs to nobody.
@MainActor
final class ReinstallWithoutServerTests: XCTestCase {

    private let serverKey = "openwebui.baseURL"
    private var savedServer: String?
    private let keychain = OWKeychainStore()

    override func setUp() {
        super.setUp()
        savedServer = UserDefaults.standard.string(forKey: serverKey)
    }
    override func tearDown() {
        if let s = savedServer { UserDefaults.standard.set(s, forKey: serverKey) }
        else { UserDefaults.standard.removeObject(forKey: serverKey) }
        keychain.clear()
        super.tearDown()
    }

    func testATokenLeftFromABeforeInstallIsDroppedAndTheLoginShows() async {
        UserDefaults.standard.removeObject(forKey: serverKey)
        keychain.save(token: "left-over")

        let app = AppState()
        XCTAssertFalse(app.client.isAuthenticated, "no server saved, no session")
        XCTAssertNil(keychain.loadToken())
        await app.bootstrap()
        XCTAssertEqual(app.phase, .login)
    }

    func testATokenWithItsServerIsKept() {
        UserDefaults.standard.set("https://kept.test", forKey: serverKey)
        keychain.save(token: "mine")

        let app = AppState()
        XCTAssertTrue(app.client.isAuthenticated)
        XCTAssertEqual(keychain.loadToken(), "mine")
    }
}
