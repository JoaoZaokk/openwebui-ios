import XCTest

/// Every screen, menu, sheet and context menu of the app, saved as PNGs for
/// the owner to edit (Photoshop, design tools) — not a test of behaviour.
///
/// Runs only with `TEST_RUNNER_OW_EXPORT=<dir>`, against the local stub of the
/// App Store captures (`screenshots-2026-10/stub/server.py`, port 8778), with
/// the Debug launch arguments that sign in without the login screen. Each
/// area is its own test so one missing control does not cost the rest; a
/// control that is not found is logged and skipped, not failed.
///
///     TEST_RUNNER_OW_EXPORT=/path TEST_RUNNER_OW_LANG=pt-BR \
///       xcodebuild test -scheme OpenWebUI-UI -only-testing:OpenWebUIUITests/ExportTourUITests …
final class ExportTourUITests: XCTestCase {

    private var dir: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["OW_EXPORT"], !out.isEmpty else { throw XCTSkip("OW_EXPORT not set") }
        dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    // MARK: - Helpers

    private var lang: (String, String) {
        switch ProcessInfo.processInfo.environment["OW_LANG"] ?? "pt-BR" {
        case "en-US": return ("en", "en_US")
        default: return ("pt-BR", "pt_BR")
        }
    }

    private func launch(_ route: String = "list") {
        app = XCUIApplication()
        let (al, loc) = lang
        app.launchArguments = [
            "-openwebui.baseURL", "http://127.0.0.1:8778", "-screenshotToken", "stub-token",
            "-screenshotHost", "ai.example.com", "-odysseus.theme.id",
            ProcessInfo.processInfo.environment["OW_THEME"] ?? "openwebui",
            "-screenshotRoute", route, "-AppleLanguages", "(\(al))", "-AppleLocale", loc,
        ]
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 30)
        settle(2)
    }

    private func settle(_ s: Double = 1) { usleep(useconds_t(s * 1_000_000)) }

    private func snap(_ name: String) {
        settle(0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func note(_ what: String) {
        try? (what + "\n").data(using: .utf8).map { d in
            let url = dir.appendingPathComponent("_missing.txt")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); h.closeFile() }
            else { try d.write(to: url) }
        }
    }

    /// The first existing element with this label or identifier, among the kinds
    /// a SwiftUI control can surface as.
    private func find(_ label: String, timeout: Double = 4) -> XCUIElement? {
        let queries: [XCUIElementQuery] = [app.buttons, app.staticTexts, app.cells, app.menuItems,
                                           app.otherElements, app.switches, app.images, app.textFields]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for q in queries {
                let all = q.matching(identifier: label).allElementsBoundByIndex
                if let e = all.first(where: { $0.isHittable }) ?? all.first { return e }
            }
            let prefix = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if prefix.exists { return prefix }
            usleep(250_000)
        } while Date() < deadline
        return nil
    }

    @discardableResult
    private func tap(_ label: String, timeout: Double = 4) -> Bool {
        guard let e = find(label, timeout: timeout) else { note("tap: \(label)"); return false }
        e.tap(); settle(1.2); return true
    }

    /// `edge`: press the bubble's padding under the text. On the user's own
    /// question a press on the text starts text selection (system Copy/Look Up
    /// bar) and the app's menu, with Edit, never opens.
    @discardableResult
    /// Presses until the menu shows `expect` (two tries: the first press after
    /// a launch sometimes opens nothing).
    private func longPress(_ label: String, edge: Bool = false, expect: String) -> Bool {
        let q = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label))
        guard q.firstMatch.waitForExistence(timeout: 5) else { note("longPress: \(label)"); return false }
        for _ in 0..<2 {
            let all = q.allElementsBoundByIndex
            let e = all.first(where: { $0.isHittable }) ?? all[0]
            if edge {
                e.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 1.15)).press(forDuration: 1.2)
            } else {
                e.press(forDuration: 1.2)
            }
            settle(1.2)
            if app.buttons[expect].waitForExistence(timeout: 2) { return true }
            settle(1)
        }
        note("longPress \(label): no menu with \(expect)")
        return false
    }

    /// Closes a menu: a tap on the status bar strip touches nothing. Context
    /// menus ignore it, so after one the screen is launched again instead.
    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap(); settle(1)
    }

    private func dismissSheet() {
        for l in ["Cancelar", "Fechar", "OK", "Concluído", "Pronto", "Cancel", "Close", "Done"] {
            let b = app.buttons[l]
            if b.exists && b.isHittable { b.tap(); settle(1.2); return }
        }
        app.swipeDown(velocity: .fast); settle(1.2)
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() } else { app.swipeRight() }
        settle(1.2)
    }

    private func tab(_ index: Int) {
        let b = app.tabBars.firstMatch.buttons.element(boundBy: index)
        if b.exists { b.tap(); settle(1.5) } else { note("tab \(index)") }
    }

    @discardableResult
    private func newMenu() -> Bool {
        let b = app.buttons["chats.newMenu"]
        guard b.waitForExistence(timeout: 4) else { note("chats.newMenu"); return false }
        b.tap(); settle(1); return true
    }

    private var pt: Bool { lang.0 == "pt-BR" }
    private func t(_ pt: String, _ en: String) -> String { self.pt ? pt : en }

    // MARK: - Conversas

    func test01Conversas() {
        launch()
        snap("conversas-01-lista")

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap(); settle(1)
            snap("conversas-02-busca-teclado")
            search.typeText(t("foto", "photo")); settle(1.5)
            snap("conversas-03-busca-resultado")
        } else { note("search field") }
        launch()

        if newMenu() {
            snap("conversas-04-menu-nova")
            dismissMenu()
        }

        if longPress(t("Panquecas", "Pancakes"), expect: t("Renomear", "Rename")) {
            snap("conversas-05-menu-contexto")
            launch()
        }

        let cell = app.cells.element(boundBy: 1)
        if cell.exists {
            cell.swipeLeft(); settle(1)
            snap("conversas-06-deslizar-esquerda")
            cell.swipeRight(); settle(1)
            cell.swipeRight(); settle(1)
            snap("conversas-07-deslizar-direita")
            cell.swipeLeft(); settle(1)
        }

        if longPress(t("Panquecas", "Pancakes"), expect: t("Renomear", "Rename")), tap(t("Renomear", "Rename")) {
            snap("conversas-08-renomear")
            dismissSheet()
        }

        if newMenu(), tap(t("Arquivadas", "Archived")) {
            snap("conversas-09-arquivadas")
            dismissSheet()
        }

        if newMenu(), tap(t("Conversa temporária", "Temporary chat")) {
            settle(1.5)
            snap("conversas-10-temporaria")
            back()
        }

        if newMenu(), tap("chats.new") {
            settle(1)
            snap("conversas-11-nova")
            back()
        }
    }

    // MARK: - Conversa

    func test02Chat() {
        launch("chat:c-lisboa")
        settle(3)
        snap("chat-01-resposta-com-sugestoes")
        app.swipeDown(); app.swipeDown(); settle(1)
        snap("chat-02-topo")
        app.swipeUp(); app.swipeUp(); settle(1)

        app.buttons["chat.modelMenu"].tap(); settle(1)
        snap("chat-03-menu-modelos")
        if let sub = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", t("Imagem", "Image"))).firstMatch as XCUIElement?,
           sub.exists {
            sub.tap(); settle(1)
            snap("chat-04-submenu-tipo-de-modelo")
        } else { note("model kind submenu") }
        dismissMenu(); dismissMenu()

        if tap(t("Anexar", "Attach")) {
            snap("chat-05-menu-anexar")
            dismissMenu()
        }

        if tap(t("Ferramentas", "Tools")) {
            settle(1.5)
            snap("chat-06-ferramentas")
            dismissSheet()
        }

        if tap(t("Buscar na web", "Search the web")) {
            snap("chat-07-busca-web-ligada")
            tap(t("Buscar na web", "Search the web"))
        }

        let field = app.descendants(matching: .any)["composer.field"]
        if field.waitForExistence(timeout: 3) {
            field.tap(); settle(1.5)
            snap("chat-08-teclado")
            field.typeText(t("Obrigada! E para comer à noite?", "Thanks! And for dinner?")); settle(1)
            snap("chat-09-digitando")
        }
        launch("chat:c-lisboa")
        settle(3)

        if longPress(t("Dia 1", "Day 1"), expect: t("Regenerar", "Regenerate")) {
            snap("chat-10-menu-da-resposta")
        }
        launch("chat:c-lisboa")
        settle(3)

        // The press reads the frame once: let the scroll come to rest first.
        app.swipeDown(); app.swipeDown(); settle(3)
        if longPress(t("Vou passar 3 dias", "spending 3 days"), edge: true, expect: t("Editar", "Edit")) {
            snap("chat-11-menu-da-pergunta")
            if tap(t("Editar", "Edit"), timeout: 2) {
                settle(1)
                snap("chat-12-editar-pergunta")
            }
        }
        launch("chat:c-lisboa")
        settle(3)

        let speak = app.buttons.matching(identifier: "message.speak")
        if speak.count >= 2 {
            speak.element(boundBy: speak.count - 1).tap(); settle(1.5)
            snap("chat-13-lendo-em-voz-alta")
            speak.element(boundBy: speak.count - 1).tap(); settle(1)
        }

        if tap(t("Conversa por voz", "Voice chat")) {
            settle(2)
            snap("chat-14-modo-de-voz")
            dismissSheet()
        }
    }

    func test03ChatWebAndCode() {
        launch("chat:c-foto")
        settle(3)
        snap("chat-15-busca-na-web")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", t("fotossíntese explicação", "photosynthesis simple"))).firstMatch
        if card.waitForExistence(timeout: 3) {
            card.tap(); settle(1.5)
            snap("chat-16-busca-na-web-fontes")
        } else { note("web search card") }

        launch("chat:c-codigo")
        settle(3)
        snap("chat-17-codigo")
    }

    func test04ChatStreaming() {
        let q = t("Me dá 3 ideias de lanche saudável para levar ao trabalho?",
                  "Give me 3 healthy snack ideas to take to work?")
        launch("ask:\(q)")
        settle(3)
        snap("chat-18-respondendo")
        settle(8)
        snap("chat-19-resposta-e-sugestoes")
    }

    // MARK: - Abas

    func test05Notas() {
        launch("notes")
        snap("notas-01-lista")
        if tap(t("Reunião de produto", "Product meeting")) {
            settle(1.5)
            snap("notas-02-nota-aberta")
            dismissSheet()
        }
        if tap(t("Nova nota", "New note")) {
            settle(1.5)
            snap("notas-03-nova-nota")
            dismissSheet()
        }
        let cell = app.cells.firstMatch
        if cell.exists {
            cell.swipeLeft(); settle(1)
            snap("notas-04-deslizar")
            cell.swipeRight(); settle(1)
        }
    }

    func test06Imagem() {
        launch()
        tab(2)
        snap("imagem-01-vazia")
        if let size = find("1024x1024") { size.tap(); settle(1); snap("imagem-02-menu-tamanho"); dismissMenu() }
        if let model = find(t("Padrão", "Default")) { model.tap(); settle(1); snap("imagem-03-menu-modelo"); dismissMenu() }

        let fields = app.textViews.count > 0 ? app.textViews : app.textFields
        if fields.count >= 2 {
            let idea = fields.element(boundBy: 0)
            idea.tap(); idea.typeText(t("um farol no fim de tarde", "a lighthouse at dusk")); settle(1)
            snap("imagem-04-assistente-de-prompt")
            let prompt = fields.element(boundBy: 1)
            prompt.tap()
            prompt.typeText(t("Um farol à beira-mar ao pôr do sol, ilustração minimalista",
                              "A lighthouse by the sea at sunset, minimalist illustration"))
            if !tap(t("Concluído", "Done"), timeout: 2) { app.swipeDown(velocity: .fast) }
            snap("imagem-05-prompt")
        } else { note("image text fields: \(app.textViews.count) views / \(app.textFields.count) fields") }

        if tap(t("Gerar imagem", "Generate image")) {
            settle(0.6)
            snap("imagem-06-gerando")
            settle(8)
            snap("imagem-07-resultado")
            let img = app.images.allElementsBoundByIndex.last
            if let img, img.exists {
                img.tap(); settle(1.5)
                snap("imagem-08-visualizador")
                dismissSheet()
            }
        }
        if tap(t("Histórico", "History")) {
            settle(1.5)
            snap("imagem-09-historico")
            dismissSheet()
        }
    }

    func test07Voz() {
        launch("voicetab")
        settle(1.5)
        snap("voz-01-aba")
        if let m = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mimo")).firstMatch as XCUIElement?, m.exists {
            m.tap(); settle(1)
            snap("voz-02-menu-modelo")
            dismissMenu()
        } else { note("voice model picker") }
    }

    func test08Workspace() {
        launch("workspace")
        snap("workspace-01-topo")
        app.swipeUp(); settle(1)
        snap("workspace-02-meio")
        app.swipeUp(); app.swipeUp(); settle(1)
        snap("workspace-03-fim")
    }

    // MARK: - Ajustes e login

    func test09Ajustes() {
        launch("settings")
        settle(1.5)
        snap("ajustes-01-topo")
        app.swipeUp(); settle(1)
        snap("ajustes-02-fim")
        app.swipeDown(); settle(1)

        let pages: [(String, String, String)] = [
            (t("Idioma", "Language"), "ajustes-03-idioma", ""),
            (t("Tema", "Theme"), "ajustes-04-tema", "ajustes-05-tema-fim"),
            (t("Nomes dos modelos", "Model names"), "ajustes-06-nomes-dos-modelos", ""),
            (t("Voz e modelos", "Voice & models"), "ajustes-07-voz-e-modelos", "ajustes-08-voz-e-modelos-fim"),
            (t("Diagnóstico", "Diagnostics"), "ajustes-09-diagnostico", "ajustes-10-diagnostico-fim"),
        ]
        for (label, first, second) in pages {
            if !find(label, timeout: 2).map({ $0.isHittable }).orFalse { app.swipeUp(); settle(1) }
            guard tap(label) else { continue }
            settle(1.5)
            snap(first)
            if !second.isEmpty {
                app.swipeUp(); app.swipeUp(); settle(1)
                snap(second)
            }
            back()
            app.swipeDown(); settle(0.5)
        }

        app.swipeUp(); settle(1)
        if tap(t("Reportar bug", "Report a bug")) {
            settle(1.5)
            snap("ajustes-11-reportar-bug")
            dismissSheet()
        }
        if tap(t("Endereço", "Address")) {
            settle(1.5)
            snap("ajustes-12-servidor")
            dismissSheet()
        }
        if tap(t("Sair", "Sign out")) {
            settle(3)
            snap("login-01-entrar")
            if let server = find("login.server", timeout: 3) ?? find("ai.example.com", timeout: 2) {
                server.tap(); settle(1.5)
                snap("login-02-servidor")
                dismissSheet()
            } else { note("login server label") }
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
