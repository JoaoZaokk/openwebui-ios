import XCTest

/// Signing in through the system browser (issue #13, Open WebUI 0.13
/// `auth_sessions`), against the stub server started with the browser sign-in
/// switched on.
///
/// The stub answers the server's own sign-in page with a redirect straight to
/// the app's loopback listener — a person already signed in on the web — so what
/// is exercised here is everything on the phone's side: the login screen offering
/// the option, the listener, the system sheet and its "wants to use … to sign in"
/// alert, the code exchange, and landing in the app.
///
///     STUB_AUTH_SESSIONS=1 STUB_LANG=pt-BR python3 stub/server.py 8779 &
///     TEST_RUNNER_OW_STUB_AUTH=http://127.0.0.1:8779 \
///       xcodebuild test -scheme OpenWebUI-UI -only-testing:OpenWebUIUITests/BrowserSignInUITests …
///
/// Unlike `StubScreensUITests` this launches WITHOUT `-screenshotToken`: that
/// argument signs the app in under a separate Keychain and skips the login
/// screen, which is exactly the screen under test.
final class BrowserSignInUITests: XCTestCase {

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        guard let stub = ProcessInfo.processInfo.environment["OW_STUB_AUTH"], !stub.isEmpty else {
            throw XCTSkip("OW_STUB_AUTH not set")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-openwebui.baseURL", stub, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
        ] + extra
        app.launch()
        return app
    }

    /// The Keychain outlives the app, so a previous run (or the person's own
    /// session on this simulator) can leave the app signed in: sign out first,
    /// so the test really does begin on the login screen.
    private func reachLoginScreen(_ app: XCUIApplication) {
        let browser = app.buttons["login.browser"]
        let tabBar = app.tabBars.firstMatch
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !browser.exists, !tabBar.exists { usleep(300_000) }
        if browser.exists { return }
        XCTAssertTrue(tabBar.exists, "neither the login screen nor the tab bar appeared")
        app.buttons["Ajustes"].tap()
        for _ in 0..<6 where !app.buttons["Sair"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Sair"].waitForExistence(timeout: 5), "no Sair in Ajustes")
        app.buttons["Sair"].tap()
        XCTAssertTrue(browser.waitForExistence(timeout: 30), "no login screen after Sair")
    }

    /// "«OpenWebUI» wants to use «127.0.0.1» to sign in" — the system's own
    /// alert, answered with its Continue button.
    private func acceptSystemSignInAlert(timeout: TimeInterval = 30) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in ["Continuar", "Continue"] {
                let button = springboard.alerts.buttons[label]
                if button.exists { button.tap(); return true }
            }
            usleep(300_000)
        }
        return false
    }

    func testTheLoginScreenOffersTheBrowserAndSignsInThroughIt() throws {
        let app = try launch()
        reachLoginScreen(app)

        let option = app.buttons["login.browser"]
        XCTAssertTrue(option.exists)
        XCTAssertEqual(option.label, "Entrar pelo navegador")
        if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("login-navegador.png"))
        }
        option.tap()

        XCTAssertTrue(acceptSystemSignInAlert(), "the system sign-in alert never appeared")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 90), "no tab bar after the browser sign-in")
    }
}
