import XCTest
@testable import OpenWebUI

/// A clean install opened in Hermes' electric blue while the app icon is the
/// black Open WebUI "OI". The default is now the Open WebUI skin, on the
/// primary icon, so a first launch changes no icon and shows no alert.
@MainActor
final class DefaultThemeTests: XCTestCase {

    private let key = "odysseus.theme.id"
    private var saved: String?

    override func setUp() { super.setUp(); saved = UserDefaults.standard.string(forKey: key) }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testACleanInstallOpensInTheOpenWebUISkin() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ThemeStore().theme.id, "openwebui")
    }

    func testTheDefaultSkinUsesThePrimaryIcon() {
        XCTAssertNil(AppIconManager.iconName(for: Theme.defaultID), "a first launch would switch icons and show the system alert")
    }

    func testAChosenThemeIsKept() {
        UserDefaults.standard.set("hermes", forKey: key)
        XCTAssertEqual(ThemeStore().theme.id, "hermes")
    }
}
