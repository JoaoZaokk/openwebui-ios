import XCTest

/// The walkthrough, as a test that can be run again.
///
/// Types the owner fixture (`.ow-test-login`: server, email, senha) into the
/// login screen, signs in against the real server, opens every tab, then holds
/// a conversation and plays it back — the 🔊 on the reply *and* on the message
/// that was sent. Screenshots go to the result bundle, and to `OW_SHOTS` when
/// that is set, so a run can be looked at afterwards.
///
///     TEST_RUNNER_OW_FIXTURE=$PWD/.ow-test-login TEST_RUNNER_OW_SHOTS=/tmp/shots \
///       xcodebuild test -scheme OpenWebUI-UI -destination 'platform=iOS Simulator,name=…'
final class WalkthroughUITests: XCTestCase {

    private struct Fixture { let server, email, senha: String }

    private func fixture() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(env["OW_FIXTURE"], "set TEST_RUNNER_OW_FIXTURE to the .ow-test-login path")
        var fields: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return Fixture(server: try XCTUnwrap(fields["server"]),
                       email: try XCTUnwrap(fields["email"]),
                       senha: try XCTUnwrap(fields["senha"]))
    }

    private var shot = 0
    private func snap(_ app: XCUIApplication, _ name: String) {
        shot += 1
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["OW_SHOTS"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", shot, name))
            try? png.write(to: url)
        }
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Agora Não", "Not Now", "Permitir", "Allow", "Permitir Durante o Uso", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()
        return app
    }

    /// Server sheet (first run), email, Senha, Entrar. Done when the tab bar shows.
    private func signIn(_ app: XCUIApplication, _ f: Fixture) {
        let tabBar = app.tabBars.firstMatch
        let email = app.textFields["login.email"]
        let url = app.textFields["server.url"]
        // Whichever screen the launch lands on first.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !tabBar.exists, !email.exists, !url.exists { usleep(300_000) }
        if tabBar.exists { return }

        if url.exists {
            url.tap()
            url.typeText(f.server)
            snap(app, "servidor")
            app.buttons["server.save"].tap()
        }
        XCTAssertTrue(email.waitForExistence(timeout: 60), "login screen never showed the email field")
        snap(app, "login")
        email.tap()
        email.typeText(f.email)
        let pass = app.secureTextFields["login.pass"]
        XCTAssertTrue(pass.waitForExistence(timeout: 5))
        pass.tap()
        pass.typeText(f.senha)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(tabBar.waitForExistence(timeout: 90), "no tab bar after Entrar")
        // iOS offers to save the password after a sign-in, sometimes ten
        // seconds later; it sits over the list and swallows the next tap.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline2 = Date().addingTimeInterval(15)
        while Date() < deadline2 {
            if let notNow = [app.buttons["Agora Não"], springboard.buttons["Agora Não"]].first(where: \.exists) {
                notNow.tap(); break
            }
            usleep(300_000)
        }
    }

    /// Answers a system alert (notifications, saved password) if one is up.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Permitir", "Allow", "Agora Não", "Not Now"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: label == "Permitir" ? 3 : 0.5) { b.tap(); return }
        }
    }

    /// Taps a menu and waits for one of its items; a tap the system ate is tried again.
    private func open(_ app: XCUIApplication, menu: String, item: String) {
        for _ in 0..<3 {
            app.buttons[menu].tap()
            if app.buttons[item].waitForExistence(timeout: 4) { return }
        }
        XCTFail("\(menu) never showed \(item)")
    }

    /// Sends one short message in a new chat and waits for the reply to settle.
    private func converse(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        app.tabBars.firstMatch.buttons.element(boundBy: 0).tap()
        open(app, menu: "chats.newMenu", item: "chats.new")
        app.buttons["chats.new"].tap()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(text)
        app.buttons["composer.send"].tap()
        let speak = app.buttons.matching(identifier: "message.speak")
        let settled = NSPredicate { _, _ in speak.count >= 2 && app.buttons["composer.send"].exists }
        expectation(for: settled, evaluatedWith: NSObject())
        waitForExpectations(timeout: 180)
        return speak
    }

    /// The server this app talks to has no text-to-speech engine configured
    /// (`audio.tts.engine` is "" — /audio/speech answers 404). With the voice set
    /// to "Servidor", the 🔊 used to spin and fall silent with nothing on screen.
    func testServerVoiceWithoutAnEngineSaysSoAndStillReads() throws {
        let f = try fixture()
        let app = launch(["-voice.tts.engine", "server"])
        signIn(app, f)
        let speak = converse(app, "Diga apenas: teste de voz.")
        speak.element(boundBy: 1).tap()
        let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "motor de voz")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 30), "no reason on screen for the silent server voice")
        XCTAssertTrue(app.buttons["Parar leitura"].waitForExistence(timeout: 10), "the device voice did not take over")
        snap(app, "voz-servidor-sem-motor")
    }

    /// A long press on the words of a sent question opens the message menu,
    /// with Editar. `.textSelection` on the user's bubble used to take the
    /// press: the system's Copiar / Pesquisar / Traduzir bar came up instead,
    /// and Editar opened only from the bubble's padding.
    func testALongPressOnTheSentQuestionOffersEdit() throws {
        let f = try fixture()
        let app = launch()
        signIn(app, f)
        // Two lines, as most questions are: a one-line one opened the menu even
        // with the bug.
        let question = "Responda só: ok. Esta pergunta é longa de propósito, para ocupar duas linhas no balão."
        _ = converse(app, question)
        dismissSystemAlert()
        // The chat's title is the same words until the server names it: the
        // bubble is the lower of the two.
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", question))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        let text = try XCTUnwrap(matches.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY })
        text.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Editar"].waitForExistence(timeout: 5),
                      "the press on the question did not open the message menu")
        snap(app, "menu-da-pergunta")
        app.buttons["Editar"].tap()
        XCTAssertTrue(app.buttons["Cancelar"].waitForExistence(timeout: 5), "Editar did not open the editor")
        snap(app, "editando-pergunta")
        app.buttons["Cancelar"].tap()
    }

    /// Voice mode had no web search at all: a question about today was answered
    /// from memory, or — with Gemma 4 through LM Studio — with a search command
    /// read out as the reply. The model now gets a `search_web` it can call and
    /// the app runs it. `-voiceSay` stands in for the microphone.
    func testVoiceModeSearchesTheWebWhenTheQuestionNeedsIt() throws {
        let f = try fixture()
        let app = launch(["-voiceSay", "Pesquise na web: qual é a cotação do dólar em reais hoje?",
                          "-voice.bargein.enabled", "NO"])
        signIn(app, f)
        let tab = app.tabBars.firstMatch.buttons["Voz"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let start = app.buttons["Iniciar conversa"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let sources = app.descendants(matching: .any)["voice.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 240), "the reply never showed the sites it searched")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the scripted session did not end")
        let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tool_call' OR label CONTAINS 'call:search'"))
        XCTAssertEqual(raw.count, 0)
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'real' OR label CONTAINS[c] 'R$' OR label CONTAINS[c] 'dólar'"))
        XCTAssertGreaterThan(reply.count, 1, "no answer about the dollar besides the question")
        snap(app, "voz-busca-na-web")
    }

    func testSignInEveryTabAndListenToBothSidesOfAConversation() throws {
        let f = try fixture()
        let app = launch()
        signIn(app, f)
        snap(app, "conversas")

        // Every tab, as a user would open them.
        let tabs = app.tabBars.firstMatch.buttons
        for i in 1..<tabs.count {
            tabs.element(boundBy: i).tap()
            sleep(3)
            app.tap()   // lets the interruption monitor answer a permission prompt
            snap(app, "aba-\(i)")
        }
        tabs.element(boundBy: 0).tap()

        // Ajustes, and the screens behind it the protocol asks for.
        let gear = app.buttons["Ajustes"]
        if gear.waitForExistence(timeout: 10) {
            gear.tap()
            sleep(2)
            snap(app, "ajustes")
            for entry in ["Nomes dos modelos", "Diagnóstico"] {
                let row = app.buttons[entry].exists ? app.buttons[entry] : app.staticTexts[entry]
                if row.waitForExistence(timeout: 5) {
                    row.tap(); sleep(2)
                    snap(app, entry == "Diagnóstico" ? "diagnostico" : "nomes-dos-modelos")
                    app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
                }
            }
            // Close the settings sheet.
            app.swipeDown(velocity: .fast)
            sleep(1)
            if app.buttons["Ajustes"].exists == false { app.swipeDown(velocity: .fast) }
        }

        // A new conversation.
        open(app, menu: "chats.newMenu", item: "chats.new")
        app.buttons["chats.new"].tap()

        let model = app.buttons["chat.modelMenu"]
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        model.tap()
        sleep(1)
        snap(app, "menu-modelos")
        // Close the menu without picking anything.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Responda só com uma frase curta: olá, tudo certo.")
        app.buttons["composer.send"].tap()

        // Both 🔊 exist once the reply has settled: the sent one, and the reply's.
        let speak = app.buttons.matching(identifier: "message.speak")
        let settled = NSPredicate { _, _ in speak.count >= 2 && app.buttons["composer.send"].exists }
        expectation(for: settled, evaluatedWith: NSObject())
        waitForExpectations(timeout: 180)
        snap(app, "conversa-respondida")

        // The reply.
        speak.element(boundBy: 1).tap()
        XCTAssertTrue(listening(app), "the reply's 🔊 produced neither audio nor a reason")
        snap(app, "ouvindo-resposta")
        speak.element(boundBy: 1).tap()   // stop

        // The message that was sent.
        speak.element(boundBy: 0).tap()
        XCTAssertTrue(listening(app), "the sent message's 🔊 produced neither audio nor a reason")
        snap(app, "ouvindo-enviada")
    }

    /// Issue #15: the questions the server suggests show up under the reply, a
    /// tap asks the next one, and they are on the server — a fresh launch reads
    /// them back from the chat, from the same `followUps` field the web reads.
    func testFollowUpsAppearAndATapAsksTheNextQuestion() throws {
        let f = try fixture()
        var app = launch()
        signIn(app, f)
        _ = converse(app, "Em uma frase: o que é fotossíntese?")

        let suggestions = app.buttons.matching(identifier: "chat.followUp")
        // The server's task model has taken 119 s on a bad call; the app waits 180.
        XCTAssertTrue(suggestions.firstMatch.waitForExistence(timeout: 200), "no suggestions under the reply")
        snap(app, "sugestoes")

        // The first reply is when the app asks for notifications; that alert
        // sits over the list and would take the tap.
        dismissSystemAlert()
        let question = suggestions.firstMatch.label
        // The list lands while the chat is still scrolling to show it. Once
        // (15/10, server 0.12.2) the tap went nowhere — no alert in the way,
        // the list unchanged for six minutes after. Tap when the list has
        // stopped moving, and again if nothing started.
        var started = false
        for _ in 0..<3 where !started {
            var last = CGRect.null
            for _ in 0..<10 where suggestions.firstMatch.frame != last {
                last = suggestions.firstMatch.frame
                usleep(700_000)
            }
            suggestions.firstMatch.tap()
            // Started: the stop button, or the list gone (a quick reply can end
            // before the stop button is seen) or already replaced.
            started = app.buttons["composer.stop"].waitForExistence(timeout: 15)
                || !suggestions.firstMatch.exists || suggestions.firstMatch.label != question
        }
        XCTAssertTrue(started, "the tap did not start a turn")
        // The list goes away while the reply streams, so a text with the
        // question's words is now the message that was sent.
        XCTAssertTrue(app.staticTexts[question].exists, "the tapped question was not what was sent")
        // Settled: a new list, under the new reply.
        let renewed = NSPredicate { _, _ in
            app.buttons["composer.send"].exists && suggestions.firstMatch.exists
                && suggestions.firstMatch.label != question
        }
        expectation(for: renewed, evaluatedWith: NSObject())
        waitForExpectations(timeout: 380)
        snap(app, "sugestao-respondida")
        let latest = suggestions.firstMatch.label
        sleep(3)   // the save goes after the questions show

        // A new process: nothing local left, the chat comes from the server.
        app.terminate()
        app = launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        let first = app.collectionViews.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        XCTAssertTrue(suggestions.firstMatch.waitForExistence(timeout: 30), "the server did not keep them")
        XCTAssertEqual(suggestions.firstMatch.label, latest)
        snap(app, "sugestoes-reabertas")
    }

    /// Ajustes › Conversa › "Sugestões de continuação" off: nothing is asked for.
    func testWithTheSwitchOffNoSuggestionsAreShown() throws {
        let f = try fixture()
        let app = launch(["-chat.followUps", "NO"])
        signIn(app, f)
        _ = converse(app, "Responda só: ok.")
        XCTAssertFalse(app.buttons["chat.followUp"].waitForExistence(timeout: 25))
        snap(app, "sugestoes-desligadas")
    }

    /// True once a 🔊 turned into "stop reading" (it is playing), or a failure
    /// banner appeared saying why the chosen voice could not.
    private func listening(_ app: XCUIApplication) -> Bool {
        let playing = app.buttons["Parar leitura"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if playing.exists { return true }
            if app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "voz do aparelho")).count > 0 {
                return true
            }
            usleep(250_000)
        }
        return false
    }
}
