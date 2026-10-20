import XCTest

/// Screens checked against the stub server of the App Store captures, whose
/// chats are fixed, for what the real server can't be made to say on demand
/// (`openwebui-appstore-deliver/screenshots-2026-10/stub/server.py`).
///
/// Runs only with `TEST_RUNNER_OW_STUB` set to the stub's address. The Debug
/// launch arguments sign in without the login screen, with a token kept apart
/// from the real session.
///
///     STUB_LANG=pt-BR python3 stub/server.py 8778 &
///     TEST_RUNNER_OW_STUB=http://127.0.0.1:8778 \
///       xcodebuild test -scheme OpenWebUI-UI -only-testing:OpenWebUIUITests/StubScreensUITests …
final class StubScreensUITests: XCTestCase {

    private func launch(_ route: String, _ extra: [String] = []) throws -> XCUIApplication {
        guard let stub = ProcessInfo.processInfo.environment["OW_STUB"], !stub.isEmpty else {
            throw XCTSkip("OW_STUB not set")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-openwebui.baseURL", stub, "-screenshotToken", "stub-token",
            "-screenshotRoute", route, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
        ] + extra
        app.launch()
        return app
    }

    /// A question further up a chat, reached by scrolling: a long press on its
    /// words selected a word (the system's Copiar / Pesquisar / Traduzir bar)
    /// instead of opening the message menu, so Editar was out of reach.
    func testALongPressOnAQuestionUpTheChatOffersEdit() throws {
        // Which of the two wins the press varies from one try to the next, so
        // one green press proves nothing: every try must open the menu.
        var missed: [Int] = []
        for attempt in 1...5 {
            let app = try launch("chat:c-lisboa", ["-odysseus.theme.id", "openwebui"])
            XCTAssertTrue(app.buttons["Conversa por voz"].waitForExistence(timeout: 30))
            sleep(3)
            app.swipeDown(); app.swipeDown()
            sleep(3)
            let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Vou passar 3 dias"))
            XCTAssertTrue(question.firstMatch.waitForExistence(timeout: 5))
            question.firstMatch.press(forDuration: attempt.isMultiple(of: 2) ? 1.2 : 1.5)
            if !app.buttons["Editar"].waitForExistence(timeout: 5) {
                missed.append(attempt)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "sem-menu-\(attempt)"; shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
        }
        XCTAssertEqual(missed, [], "the press on the question did not open the message menu")
    }

    /// Voice mode resumes a chat with its history, and the replies there are
    /// markdown. They were shown as typed: "### Dia 1 — Alfama e Baixa",
    /// "- Manhã no **Castelo de São Jorge**".
    func testVoiceModeShowsTheReplyFormattedNotItsMarkdown() throws {
        let app = try launch("chat:c-lisboa")
        let voice = app.buttons["Conversa por voz"]
        XCTAssertTrue(voice.waitForExistence(timeout: 30))
        voice.tap()
        XCTAssertTrue(app.buttons["Iniciar conversa"].waitForExistence(timeout: 10))

        let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '###' OR label CONTAINS '**'"))
        XCTAssertEqual(raw.count, 0, "markdown shown as typed: \(raw.count > 0 ? raw.firstMatch.label : "")")
        XCTAssertTrue(app.staticTexts["Dia 1 — Alfama e Baixa"].exists, "the heading is not a line of its own")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "modo-de-voz"; shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - A tool call written out as text (1.10, Gemma 4 through LM Studio)

    /// The stub answers a question about Flamengo the way Gemma did in the
    /// report: `<tool_call>call:search_web{queries:[…]}</tool_call>` as plain
    /// text, and a real answer only once the request carries search results.
    private static let flamengo = "Quem ganhou o último jogo do Flamengo?"

    private func noCallShown(_ app: XCUIApplication) {
        let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tool_call' OR label CONTAINS 'call:search'"))
        XCTAssertEqual(raw.count, 0, "the call was shown: \(raw.count > 0 ? raw.firstMatch.label : "")")
    }

    private func searchesTheStubSaw() throws -> [[String]] {
        let stub = try XCTUnwrap(ProcessInfo.processInfo.environment["OW_STUB"])
        let data = try Data(contentsOf: try XCTUnwrap(URL(string: stub + "/stub/searches")))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String]])
    }

    func testVoiceModeSearchesWhenTheModelWritesOutACall() throws {
        let before = try? searchesTheStubSaw().count
        // The Voz tab: a new conversation, nothing else on screen to match.
        let app = try launch("voicetab", ["-voiceSay", Self.flamengo, "-voice.bargein.enabled", "NO"])
        let start = app.buttons["Iniciar conversa"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()

        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'venceu por 2 a 1'"))
        XCTAssertTrue(answer.firstMatch.waitForExistence(timeout: 60), "no answer after the search")
        noCallShown(app)
        let labels = answer.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { !$0.contains("[1]") }, "citation marker left in the transcript: \(labels)")
        XCTAssertTrue(app.descendants(matching: .any)["voice.sources"].waitForExistence(timeout: 5),
                      "the sites the answer came from are not shown")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "voz-com-busca"; shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the scripted session did not end")

        let searches = try searchesTheStubSaw()
        XCTAssertEqual(searches.count, (before ?? 0) + 1, "one search for the turn")
        XCTAssertEqual(searches.last, ["resultado último jogo Flamengo"], "the model's own query was searched")
    }

    func testAChatReplyThatIsACallSearchesInsteadOfShowingIt() throws {
        let app = try launch("chat:c-lisboa")
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(Self.flamengo)
        app.buttons["composer.send"].tap()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'venceu por 2 a 1'"))
        XCTAssertTrue(answer.firstMatch.waitForExistence(timeout: 60), "no answer after the search")
        noCallShown(app)
        // The card lists the sites searched, not the query the server named
        // its own sources frame after.
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Busca na web'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no web-search card under the reply")
        card.tap()
        XCTAssertTrue(app.links.matching(NSPredicate(format: "label CONTAINS 'ge.globo.com'")).firstMatch
                        .waitForExistence(timeout: 5), "the card does not list the sites")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-com-busca"; shot.lifetime = .keepAlways
        add(shot)
    }

    /// "Buscar na web" on: the app searches first, then the server opens its
    /// reply with a sources frame named after the query and without addresses.
    /// It replaced the sites, so the card held one entry with no link.
    func testWithSearchOnTheCardListsTheSitesNotTheQuery() throws {
        let app = try launch("chat:c-lisboa")
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        app.buttons["Buscar na web"].tap()
        field.tap()
        field.typeText("Que horas abre o Castelo de São Jorge hoje?")
        app.buttons["composer.send"].tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Busca na web'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no web-search card under the reply")
        XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 60))
        card.tap()
        XCTAssertTrue(app.links.matching(NSPredicate(format: "label CONTAINS 'ge.globo.com'")).firstMatch
                        .waitForExistence(timeout: 5), "the card does not list the sites")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-busca-ligada"; shot.lifetime = .keepAlways
        add(shot)
    }
}
