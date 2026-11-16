import XCTest

/// A server reached by plain `http://` under a NAME (not an IP, not `.local`):
/// the case the system itself refuses and 1.12 handled in silence — the login
/// screen looked fine and every request failed with a number nobody can read.
/// Since 1.14 the Servidor screen asks first, and only what the person
/// confirmed leaves the phone.
///
///     STUB_QUIET=1 python3 testing/stub/server.py 8781 &
///     TEST_RUNNER_OW_REACH_URL=http://localtest.me:8781 xcodebuild test …
///
/// `localtest.me` resolves to 127.0.0.1 but is a qualified name, so it is not
/// covered by NSAllowsLocalNetworking — the same position as `box.tail1234.ts.net`.
final class ServerReachabilityUITests: XCTestCase {

    private func launch() throws -> (XCUIApplication, String) {
        guard let url = ProcessInfo.processInfo.environment["OW_REACH_URL"], !url.isEmpty else {
            throw XCTSkip("OW_REACH_URL not set")
        }
        let app = XCUIApplication()
        // Another host first, then the person types the address in the Servidor sheet.
        app.launchArguments = ["-openwebui.baseURL", "https://example.invalid",
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        return (app, url)
    }

    func testHTTPToANamedServerAsksFirstAndThenWorks() throws {
        let (app, url) = try launch()
        let server = app.staticTexts["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 60), "no login screen")
        // Typed with an unreachable placeholder the failure is shown, not hidden.
        XCTAssertTrue(app.staticTexts["login.serverProbeError"].waitForExistence(timeout: 30),
                      "a server that cannot be read says so on the login screen")

        server.tap()
        let field = app.textFields["server.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Selecionar Tudo"].waitForExistence(timeout: 2) { app.menuItems["Selecionar Tudo"].tap() }
        field.typeText(url)

        let toggle = app.switches["server.cleartext"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "http:// to a named host must ask")
        // The simulator keeps UserDefaults between runs, so a previous run's answer
        // may already be on: start from off.
        let switchOn = { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        if toggle.value as? String == "1" { switchOn() }
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.buttons["server.save"].isEnabled, "Salvar waits for the switch")
        // The row is wide and its label is not the control: tap the switch itself.
        switchOn()
        XCTAssertEqual(toggle.value as? String, "1", "the switch turned on")
        XCTAssertTrue(app.buttons["server.save"].isEnabled, "Salvar after the switch")
        app.buttons["server.save"].tap()

        // Reachable now: the login screen no longer says anything is wrong.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.staticTexts["login.serverProbeError"].exists { usleep(300_000) }
        XCTAssertFalse(app.staticTexts["login.serverProbeError"].exists,
                       "the confirmed http:// server should answer")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
