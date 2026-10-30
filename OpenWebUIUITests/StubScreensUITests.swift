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

    /// Report from 1.10 (zh_CN, iPhone 15 Pro Max): a long chat opened stopped
    /// halfway down, and after sending the screen stayed blank until scrolled
    /// back and forth. Needs the stub started with `STUB_LONG_CHAT=1`.
    func testALongChatOpensAtItsEndAndAReplyIsOnScreen() throws {
        let app = try launch("chat:c-longa")
        let window = app.windows.firstMatch
        func onScreen(_ marker: String) -> Bool {
            let e = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            return e.exists && window.frame.intersects(e.frame) && e.frame.height > 0
        }
        func shot(_ name: String) {
            let image = app.screenshot()
            let a = XCTAttachment(screenshot: image); a.name = name; a.lifetime = .keepAlways; add(a)
            // The result bundle is written only when xcodebuild exits, and on
            // Xcode 27 it does not exit after UI tests; OW_SHOTS gets them now.
            if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
                try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        XCTAssertTrue(app.buttons["Conversa por voz"].waitForExistence(timeout: 30))
        let end = NSPredicate { _, _ in onScreen("FIM-DA-CONVERSA") }
        let opened = XCTWaiter().wait(for: [expectation(for: end, evaluatedWith: nil)], timeout: 30) == .completed
        if opened { sleep(3) }
        let stays = onScreen("FIM-DA-CONVERSA")
        shot("aberta")
        XCTAssertTrue(opened, "the chat did not open at its last message")
        XCTAssertTrue(stays, "the last message left the screen after the chat opened")

        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Teste de rolagem: responda")
        app.buttons["composer.send"].tap()
        let sentShown = XCTWaiter().wait(for: [expectation(for: NSPredicate { _, _ in onScreen("Teste de rolagem") },
                                                           evaluatedWith: nil)], timeout: 10) == .completed
        shot("enviada")
        XCTAssertTrue(sentShown, "the question just sent is not on screen")
        let replied = XCTWaiter().wait(for: [expectation(for: NSPredicate { _, _ in onScreen("FIM-DA-RESPOSTA-NOVA") },
                                                         evaluatedWith: nil)], timeout: 90) == .completed
        shot("respondida")
        XCTAssertTrue(replied, "the reply did not end on screen")
    }

    /// Same report: past the model's context the web could compress the
    /// conversation, the app only showed the error. The stub answers with the
    /// provider's error until the earlier turns arrive as a summary.
    func testAConversationPastTheContextIsSummarizedAndGoesOn() throws {
        // A new chat each run: a summary is kept per chat, and one left by an
        // earlier run would already stand in for the turns.
        let app = try launch("ask:Oi")
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["message.speak"].waitForExistence(timeout: 30), "no first reply")
        XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 30))
        field.tap()
        field.typeText("Estouro de contexto: continue")
        app.buttons["composer.send"].tap()
        let offer = app.buttons["chat.summarize"]
        XCTAssertTrue(offer.waitForExistence(timeout: 20), "no summary offered after the context error")
        func save(_ n: String) {
            if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(n + ".png"))
            }
        }
        save("oferta-0"); sleep(2); save("oferta-2")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "limite de contexto")).firstMatch.exists)
        offer.tap()
        let goesOn = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Continuando depois do resumo")).firstMatch
        XCTAssertTrue(goesOn.waitForExistence(timeout: 30), "the question was not asked again with the summary")
        XCTAssertFalse(offer.exists, "the offer stays after it worked")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "resumida"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("resumida.png"))
        }
    }

    /// Options a model writes as a question to answer (🔘 lines) are offered
    /// as buttons, and a tap sends the option. Needs the stub started with
    /// `STUB_EXTRA_CHATS` holding the `r-botoes` chat.
    func testOptionsTheModelWroteAreButtonsThatAnswer() throws {
        let app = try launch("chat:r-botoes")
        let option = app.buttons.matching(identifier: "chat.replyOption").firstMatch
        guard option.waitForExistence(timeout: 30) else {
            throw XCTSkip("stub has no r-botoes chat (STUB_EXTRA_CHATS not set)")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "chat.replyOption").count, 5)
        let label = option.label
        XCTAssertTrue(label.hasPrefix("Dia 1"), label)
        option.tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the option was not sent as the next message")
    }

    /// Same report: an answer could only be copied whole. The message menu
    /// opens it in a view that selects by range.
    func testAPartOfAnAnswerCanBeSelected() throws {
        let app = try launch("chat:c-lisboa")
        XCTAssertTrue(app.buttons["Conversa por voz"].waitForExistence(timeout: 30))
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Castelo de São Jorge")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        // Earlier tests in the suite add turns to this chat; bring the answer
        // out from under the navigation bar before pressing it.
        for _ in 0..<4 where !answer.isHittable || answer.frame.minY < 150 { app.swipeDown(); sleep(1) }
        answer.press(forDuration: 1.3)
        let item = app.buttons["Selecionar texto"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Selecionar texto in the message menu")
        item.tap()
        let view = app.textViews["message.selectableText"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        XCTAssertTrue((view.value as? String ?? "").contains("Castelo de São Jorge"))
        view.press(forDuration: 1.0)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "selecao"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 5)
                      || app.buttons["Copiar"].waitForExistence(timeout: 2)
                      || app.staticTexts["Copiar"].exists,
                      "a press in the text did not start a selection")
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ge.globo.com'")).firstMatch
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
        let listed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ge.globo.com'")).firstMatch
                        .waitForExistence(timeout: 5)
        if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("busca-card.png"))
        }
        XCTAssertTrue(listed, "the card does not list the sites")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-busca-ligada"; shot.lifetime = .keepAlways
        add(shot)
    }
}
