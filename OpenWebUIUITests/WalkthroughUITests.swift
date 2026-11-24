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
            // A plain-http address asks for consent before Save works.
            let consent = app.switches["server.cleartext"]
            if consent.waitForExistence(timeout: 2), (consent.value as? String) != "1" { consent.tap() }
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
        if !tabBar.waitForExistence(timeout: 90) { snap(app, "sem-tabbar") }
        XCTAssertTrue(tabBar.exists, "no tab bar after Entrar")
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
    /// iOS 27's floating tab bar sometimes drops a tap (the screen stays where it
    /// was): tap again until something only that tab shows is there.
    private func showTab(_ app: XCUIApplication, _ index: Int, until marker: XCUIElement) {
        let tab = app.tabBars.firstMatch.buttons.element(boundBy: index)
        for _ in 0..<4 where !marker.exists {
            if tab.exists { tab.tap() }
            _ = marker.waitForExistence(timeout: 4)
        }
    }

    private func converse(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        showTab(app, 0, until: app.buttons["chats.newMenu"])
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

    /// Open Terminal, end to end: a real Open WebUI 0.13.3 with a real Open
    /// Terminal connected, and a scripted model that writes a file and then
    /// runs a command (private repo, testing/terminal-e2e). The fixture is that
    /// server's own disposable account, typed in like the owner's.
    ///
    ///     TEST_RUNNER_OW_TERMINAL_FIXTURE=…/e2e-login xcodebuild test -scheme OpenWebUI-UI \
    ///       -only-testing:OpenWebUIUITests/WalkthroughUITests/testOpenTerminalRunsFilesAndShell
    func testOpenTerminalRunsFilesAndShell() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(env["OW_TERMINAL_FIXTURE"], "set TEST_RUNNER_OW_TERMINAL_FIXTURE")
        var fields: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let f = Fixture(server: try XCTUnwrap(fields["server"]), email: try XCTUnwrap(fields["email"]),
                        senha: try XCTUnwrap(fields["senha"]))
        let app = launch()
        signIn(app, f)

        showTab(app, 0, until: app.buttons["chats.newMenu"])
        open(app, menu: "chats.newMenu", item: "chats.new")
        app.buttons["chats.new"].tap()

        // The terminal chip shows only on a server that has one.
        let chip = app.buttons["composer.terminal"]
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "no terminal chip: the server's terminal list did not arrive")
        chip.tap()
        let box = app.buttons["terminal.option.box"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap()
        snap(app, "terminal-escolhido")
        app.buttons["Pronto"].firstMatch.tap()

        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Grave um arquivo e rode um comando no terminal")
        app.buttons["composer.send"].tap()

        // 1: write_file asks first.
        let allow = app.buttons["terminal.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 90), "no approval for write_file")
        snap(app, "confirmar-gravacao")
        allow.tap()
        // 2: run_command asks too (the bar takes the first one's place).
        let command = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'uname -s'")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 90), "no approval for run_command")
        let allow2 = app.buttons["terminal.allow"]
        XCTAssertTrue(allow2.waitForExistence(timeout: 10))
        snap(app, "confirmar-comando")
        allow2.tap()

        // The model's answer quotes the command's output.
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'teste-ios'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "the reply never showed the command output")
        let card = app.buttons["terminal.card.run_command"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        snap(app, "resposta-e-cartao")

        // Files: the one the model wrote is there.
        chip.tap()
        let files = app.buttons["terminal.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        let written = app.buttons["terminal.file.ola-ios.txt"]
        XCTAssertTrue(written.waitForExistence(timeout: 30), "ola-ios.txt not in the terminal's files")
        snap(app, "arquivos")
        app.buttons["Pronto"].firstMatch.tap()

        // Shell: type a command that leaves a trace, then look for it in Files.
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let shell = app.buttons["terminal.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 10))
        shell.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.shell.view"].waitForExistence(timeout: 20))
        sleep(4)
        app.typeText("echo shell-ok > ~/shell-ok.txt && ls ~\n")
        sleep(3)
        snap(app, "shell")
        app.buttons["terminal.shell.close"].tap()

        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(app.buttons["terminal.file.shell-ok.txt"].waitForExistence(timeout: 30),
                      "what was typed in the shell did not run")
        snap(app, "arquivos-depois-do-shell")
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

    /// Report on build 27: the model's web search can be switched off from the call
    /// itself (the globe), and the same question that searches above is then
    /// answered without searching. Leaves the switch on for the other tests.
    func testTheCallScreenGlobeTurnsWebSearchOff() throws {
        let f = try fixture()
        let app = launch(["-voiceSay", "Pesquise na web: qual é a cotação do dólar em reais hoje?",
                          "-voice.bargein.enabled", "NO"])
        signIn(app, f)
        let tab = app.tabBars.firstMatch.buttons["Voz"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let globe = app.buttons["voice.webSearch"]
        XCTAssertTrue(globe.waitForExistence(timeout: 10), "no web search switch on the call screen")
        if globe.isSelected { globe.tap() }
        XCTAssertFalse(globe.isSelected, "the globe did not switch off")
        snap(app, "voz-globo-desligado")
        defer { if globe.exists && !globe.isSelected { globe.tap() } }

        let start = app.buttons["Iniciar conversa"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let running = NSPredicate { _, _ in !start.exists }
        expectation(for: running, evaluatedWith: NSObject())
        waitForExpectations(timeout: 20)
        XCTAssertTrue(start.waitForExistence(timeout: 240), "the scripted session did not end")
        snap(app, "voz-sem-busca")
        XCTAssertFalse(app.descendants(matching: .any)["voice.sources"].exists,
                       "with the globe off the reply still searched the web")
        XCTAssertGreaterThan(app.staticTexts.count, 1, "no reply")
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
        showTab(app, 0, until: app.buttons["Ajustes"])

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

    /// Report from 1.12 (iPad): on the web the model knew the person's age from
    /// Personalization › Memory and answered from their Notes; the app said it had
    /// no information. The test account holds one memory ("47 anos") and one note
    /// (the test bench is a Raspberry Pi nicknamed "tartaruga"), put there for
    /// this test.
    func testMemoryAndNotesFromTheServerReachTheReply() throws {
        let f = try fixture()
        let app = launch()
        signIn(app, f)
        _ = converse(app, "Quantos anos eu tenho? Responda só com o número.")
        snap(app, "memoria")
        let age = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "47")).firstMatch
        XCTAssertTrue(age.waitForExistence(timeout: 10), "the reply did not use the memory")

        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        field.typeText("Procure nas minhas notas: onde roda a bancada de teste do app?")
        app.buttons["composer.send"].tap()
        let found = NSPredicate { _, _ in
            app.buttons["composer.send"].exists
                && (app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "tartaruga")).count > 0
                    || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Raspberry")).count > 0)
        }
        expectation(for: found, evaluatedWith: NSObject())
        waitForExpectations(timeout: 240)
        snap(app, "notas")
    }

    /// Build 27 (Scott's report): everything downloaded in one list with its size
    /// and a way out, and the active model is a picker among the ones on the device.
    /// Needs two empty files in the app's `Application Support/Models`, named
    /// `w-tiny-ggml-tiny.bin` and `w-base-ggml-base.bin` (the catalogue's ids), so
    /// the app believes it has downloaded Whisper Tiny and Whisper Base.
    func testDownloadedModelsAreListedAndTheActiveModelIsAPicker() throws {
        let f = try fixture()
        let app = launch(["-openwebui.baseURL", f.server, "-voice.stt.engine", "model",
                          "-voice.stt.model", "w-base"])
        signIn(app, f)
        let gear = app.buttons["Ajustes"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()
        // Settings is a lazy list: rows below the fold are not in the hierarchy
        // until scrolled to (the memory and notes switches push this one down).
        let link = app.buttons["Voz e modelos"]
        for _ in 0..<6 where !link.waitForExistence(timeout: 2) { app.swipeUp() }
        if !link.exists { snap(app, "ajustes-sem-voz-e-modelos") }
        XCTAssertTrue(link.exists)
        link.tap()
        // The active model is a picker with both models on the device.
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Modelo ativo")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no active-model picker")
        snap(app, "modelo-ativo")
        picker.tap()
        XCTAssertTrue(app.buttons["Whisper Tiny"].waitForExistence(timeout: 5), "the other downloaded model is not offered")
        app.buttons["Whisper Tiny"].tap()
        // The size line opens the list of everything downloaded.
        let used = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Espaço usado")).firstMatch
        for _ in 0..<6 where !used.exists { app.swipeUp() }
        XCTAssertTrue(used.exists, "no Espaço usado row")
        used.tap()
        XCTAssertTrue(app.staticTexts["Whisper Tiny"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Whisper Base"].exists)
        snap(app, "baixados")
        // Deleting one asks first, names it, and the other stays.
        app.buttons.matching(identifier: "Apagar modelo").element(boundBy: 0).tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apagar Whisper")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snap(app, "baixados-apagar")
        confirm.tap()
        let gone = NSPredicate { _, _ in !app.staticTexts["Whisper Base"].exists || !app.staticTexts["Whisper Tiny"].exists }
        expectation(for: gone, evaluatedWith: NSObject())
        waitForExpectations(timeout: 10)
        snap(app, "baixados-depois")
    }

    /// Build 27 (Scott's report, iPhone Duo unfolded = regular width): tapping the ✕
    /// of the chat search emptied the text but kept the keyboard, and it came back
    /// after visiting a chat. Run it on an iPad: the clear button must put the
    /// keyboard away, and so must leaving for a conversation.
    func testClearingTheChatSearchPutsTheKeyboardAway() throws {
        let f = try fixture()
        let app = launch(["-openwebui.baseURL", f.server])
        // On an iPad the tab bar floats at the top and is not a UITabBar: the
        // session saved by the earlier tests is what gets us to the list. On a
        // phone, sign in (a no-op when the session is there).
        if UIDevice.current.userInterfaceIdiom == .phone { signIn(app, f) }
        let search = app.searchFields.firstMatch
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !search.exists, !app.buttons["Conversas"].exists { usleep(300_000) }
        // A phone keeps the field tucked under the title until the list is pulled down.
        if !search.exists, let list = app.collectionViews.allElementsBoundByIndex.first ?? app.tables.allElementsBoundByIndex.first {
            list.swipeDown()
            _ = search.waitForExistence(timeout: 3)
        }
        if !search.exists {
            // Regular width folds the search into a toolbar button.
            let button = app.navigationBars.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'busc' OR label CONTAINS[c] 'search' OR label CONTAINS[c] 'pesquis'")).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 20), "no search control: \(app.navigationBars.debugDescription)")
            button.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        if !app.keyboards.firstMatch.exists { search.tap() }
        search.typeText("capital")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        snap(app, "busca-teclado")
        let clear = search.buttons["Clear text"].exists ? search.buttons["Clear text"] : search.buttons.firstMatch
        XCTAssertTrue(clear.exists, "no clear button on the search field")
        clear.tap()
        let down = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        expectation(for: down, evaluatedWith: NSObject())
        waitForExpectations(timeout: 8)
        snap(app, "busca-limpa-sem-teclado")
    }

    /// Build 28 (report on build 27, video from an iPhone Duo and an iPhone 16 Pro):
    /// the ✕ of the notes search emptied the field and kept the keyboard; closing a
    /// note opened from the search brought the keyboard back over the list; and the
    /// magnifier inside a note did nothing. Makes its own note and deletes it.
    func testNotesSearchClearCloseAndFindInsideANote() throws {
        let f = try fixture()
        let app = launch(["-openwebui.baseURL", f.server])
        signIn(app, f)
        let notesTab = app.tabBars.firstMatch.buttons["Notas"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 10))
        // A tap that lands while the list is still loading can be lost.
        for _ in 0..<3 where !app.navigationBars["Notas"].exists {
            notesTab.tap()
            _ = app.navigationBars["Notas"].waitForExistence(timeout: 5)
        }
        let down = { (why: String) in
            let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
            self.expectation(for: gone, evaluatedWith: NSObject())
            self.waitForExpectations(timeout: 8) { err in if err != nil { self.snap(app, why) } }
        }

        // A note of our own, so nothing depends on what the account holds.
        let marker = "zzbusca\(Int(Date().timeIntervalSince1970) % 100_000)"
        let newNote = app.buttons["Nova nota"].firstMatch
        if !newNote.waitForExistence(timeout: 20) {
            snap(app, "notas-sem-nova-nota"); print(app.debugDescription)
            XCTFail("no Nova nota button"); return
        }
        newNote.tap()
        let title = app.textFields["Título"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText(marker)
        let body = app.textViews.firstMatch
        body.tap(); body.typeText("primeira linha\nprocure esta palavra aqui\n")
        app.buttons["Salvar"].tap()
        let row = app.staticTexts[marker]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the new note is not in the list")

        // 1. The ✕ empties the field and puts the keyboard away.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText(marker)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let clear = search.buttons["Clear text"].exists ? search.buttons["Clear text"] : search.buttons.firstMatch
        XCTAssertTrue(clear.exists, "no clear button on the notes search")
        clear.tap()
        down("notas-x-teclado-ficou")
        snap(app, "notas-x-sem-teclado")

        // 2. A note opened from a search with the keyboard up: closing it must not
        //    bring the keyboard back.
        search.tap(); search.typeText(marker)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let cancel = app.buttons["Cancelar"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the note did not open")

        // 3. The magnifier inside the note brings up a find field.
        let fields = app.textFields.count + app.searchFields.count
        app.buttons["Buscar na nota"].tap()
        let found = NSPredicate { _, _ in app.textFields.count + app.searchFields.count > fields }
        expectation(for: found, evaluatedWith: NSObject())
        waitForExpectations(timeout: 8) { err in
            if err != nil { self.snap(app, "nota-lupa-nada"); print(app.debugDescription) }
        }
        app.typeText("procure")
        snap(app, "nota-lupa-busca")

        cancel.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(2)
        snap(app, "nota-fechada")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "closing the note brought the keyboard back")

        // Clean up.
        row.swipeLeft()
        if app.buttons["Apagar"].waitForExistence(timeout: 5) { app.buttons["Apagar"].tap() }
    }

    /// Build 27 (Scott's report on build 26), against the server: search inside a
    /// chat, the notes search field, and the Workspace listing only what was made
    /// there (the account owns one workspace model; the server lists more).
    func testSearchInAChatNotesSearchAndTheWorkspaceListAgainstTheServer() throws {
        let f = try fixture()
        let app = launch(["-openwebui.baseURL", f.server])
        signIn(app, f)
        _ = converse(app, "Qual a capital da França? Responda só com o nome da cidade.")

        // Find in the conversation: accents and case are ignored.
        app.buttons["chat.find"].tap()
        let field = app.textFields["chat.find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("FRANCA")
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "no n/total counter after typing a word that is in the chat")
        snap(app, "busca-na-conversa")
        app.buttons["Próximo resultado"].tap()
        snap(app, "busca-na-conversa-proximo")
        app.buttons["Fechar"].tap()
        XCTAssertFalse(field.exists, "closing the bar left the field up")
        app.navigationBars.buttons.firstMatch.tap()

        // Notes: the list has a search field.
        app.tabBars.firstMatch.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Notas has no search field")
        snap(app, "notas-busca")

        // Workspace: the model made there, and none of the connection's own.
        app.tabBars.firstMatch.buttons.element(boundBy: 4).tap()
        // The two names are the account's: `OW_WORKSPACE_MODEL` is a model made in its
        // Workspace, `OW_CONNECTION_MODEL` one the connection lists that was not.
        let env = ProcessInfo.processInfo.environment
        if let made = env["OW_WORKSPACE_MODEL"], let notMade = env["OW_CONNECTION_MODEL"] {
            XCTAssertTrue(app.staticTexts[made].waitForExistence(timeout: 30), "the workspace model is not listed")
            XCTAssertFalse(app.staticTexts[notMade].exists, "a connection model leaked into Workspace")
        } else {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'MODELOS'")).firstMatch
                .waitForExistence(timeout: 30))
        }
        snap(app, "workspace-so-os-seus")
    }


    /// Folders against the real server: create one, give it an instruction, start a
    /// chat inside it (the reply must follow the instruction — the server applies it
    /// because the request carries `folder_id`), then delete the folder and see the
    /// conversation survive at the top level. Cleans up after itself.
    func testFoldersCreateInstructChatAndDeleteAgainstTheServer() throws {
        let f = try fixture()
        // The simulator keeps the server of the previous run in UserDefaults:
        // this test is about the account's server, so it says which.
        let app = launch(["-openwebui.baseURL", f.server])
        signIn(app, f)
        app.tabBars.firstMatch.buttons.element(boundBy: 0).tap()

        let name = "zz-ui-\(Int(Date().timeIntervalSince1970) % 100000)"
        open(app, menu: "chats.newMenu", item: "chats.newFolder")
        app.buttons["chats.newFolder"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText(name)
        alert.buttons["Salvar"].tap()
        let row = app.buttons["folder.row.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the new folder never showed in the list")
        snap(app, "pasta-criada")

        row.tap()
        XCTAssertTrue(app.staticTexts["Pasta vazia"].waitForExistence(timeout: 10))

        // The instruction.
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Instruções da pasta"].waitForExistence(timeout: 5))
        app.buttons["Instruções da pasta"].tap()
        let editor = app.textViews["folder.instructions"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Responda sempre em UMA palavra: banana.")
        snap(app, "pasta-instrucoes")
        app.buttons["folder.save"].tap()
        // The sheet closes when the save has gone through; a long press while it is
        // still going away is swallowed (the menu never opens).
        let sheetGone = NSPredicate { _, _ in !editor.exists }
        expectation(for: sheetGone, evaluatedWith: NSObject())
        waitForExpectations(timeout: 30)

        // A chat started inside the folder.
        for _ in 0..<3 {
            row.press(forDuration: 1.2)
            if app.buttons["Nova conversa nesta pasta"].waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(app.buttons["Nova conversa nesta pasta"].exists)
        app.buttons["Nova conversa nesta pasta"].tap()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Qual a capital da Noruega?")
        app.buttons["composer.send"].tap()
        let settled = NSPredicate { _, _ in
            app.buttons["composer.send"].exists
                && app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "banana")).count > 0
        }
        expectation(for: settled, evaluatedWith: NSObject())
        waitForExpectations(timeout: 180)
        snap(app, "pasta-resposta")

        // Back to the list: the chat is inside the folder, not at the top level.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        // The app titles the chat from its first answer once it exists on the server,
        // so the row may read either way.
        let chatRows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "noruega", "norway"))
        let chat = chatRows.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20), "the chat is not listed under its folder")
        // Report from 1.14: a moved chat showed in its folder AND in the main list.
        XCTAssertEqual(chatRows.count, 1, "the chat is listed twice: in its folder and at the top level")
        snap(app, "pasta-com-conversa")

        // Deleting the folder keeps the chat.
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Excluir pasta"].waitForExistence(timeout: 5))
        app.buttons["Excluir pasta"].tap()
        let confirm = app.sheets.buttons["Excluir pasta"].exists ? app.sheets.buttons["Excluir pasta"]
            : app.buttons.matching(identifier: "Excluir pasta").allElementsBoundByIndex.last!
        confirm.tap()
        let gone = NSPredicate { _, _ in !row.exists }
        expectation(for: gone, evaluatedWith: NSObject())
        waitForExpectations(timeout: 30)
        XCTAssertTrue(chat.waitForExistence(timeout: 20), "the conversation was lost with its folder")
        snap(app, "pasta-excluida")

        // Cleanup: the conversation this test made.
        chat.press(forDuration: 1.2)
        if app.buttons["Excluir"].waitForExistence(timeout: 5) { app.buttons["Excluir"].tap() }
    }

    /// Issue #13: sign-in through the system browser, where passkeys, SSO and
    /// two-step verification work. Signs out first, then types the fixture into
    /// the server's own sign-in page inside the system sheet.
    func testSignInThroughTheSystemBrowserAgainstTheServer() throws {
        let f = try fixture()
        let app = launch()
        signIn(app, f)                       // reach a known state with the right server
        app.tabBars.firstMatch.buttons.element(boundBy: 0).tap()
        let gear = app.buttons["chats.settings"]
        if gear.waitForExistence(timeout: 5) { gear.tap() } else { app.buttons["Ajustes"].firstMatch.tap() }
        for _ in 0..<8 where !app.buttons["Sair"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Sair"].waitForExistence(timeout: 5), "no Sair in Ajustes")
        app.buttons["Sair"].tap()
        if app.alerts.buttons["Sair"].waitForExistence(timeout: 3) { app.alerts.buttons["Sair"].tap() }

        let browser = app.buttons["login.browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 30), "the login screen does not offer the browser")
        snap(app, "login-navegador")
        browser.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var accepted = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !accepted {
            for label in ["Continuar", "Continue"] where springboard.alerts.buttons[label].exists {
                springboard.alerts.buttons[label].tap(); accepted = true; break
            }
            if !accepted { usleep(300_000) }
        }
        XCTAssertTrue(accepted, "the system sign-in alert never appeared")

        // The server's own sign-in page, inside the system sheet.
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let email = sheet.webViews.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 60), "the server's sign-in page did not load in the sheet")
        sleep(2)
        snap(app, "pagina-do-servidor")
        email.tap()
        email.typeText(f.email)
        let pass = sheet.webViews.secureTextFields.firstMatch
        XCTAssertTrue(pass.waitForExistence(timeout: 5))
        pass.tap()
        pass.typeText(f.senha)
        let submit = sheet.webViews.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Entrar", "Sign in")).firstMatch
        if submit.waitForExistence(timeout: 5) { submit.tap() } else { pass.typeText("\n") }

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 120), "no tab bar after signing in on the server's page")
        snap(app, "entrou-pelo-navegador")
        // A request after sign-in works with the browser session's token.
        _ = converse(app, "Responda só: ok")
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
