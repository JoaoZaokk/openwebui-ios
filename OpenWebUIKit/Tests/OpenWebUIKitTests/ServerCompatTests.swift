import XCTest
@testable import OpenWebUIKit

/// What this client must get right about the server it is pointed at.
///
/// Open WebUI 0.11 changed two things that matter here at once: it started
/// merging an incoming `history` by message id instead of replacing the whole
/// chat blob, and it started overlaying the live state of any reply still being
/// streamed onto the chat it hands back. Together those mean a save has to
/// *withhold* the messages someone else is writing — and that withholding is
/// only safe on the versions that merge. Every assertion below is that pair.
final class ServerCompatTests: XCTestCase {

    // MARK: - Which servers merge

    func testOnlyMergingServersAreTreatedAsMerging() {
        XCTAssertFalse(OpenWebUIClient.mergesHistory(version: nil),
                       "an unread version must be treated as old — never delete on a guess")
        let cases: [(String, Bool)] = [
            ("0.11.1", true), ("0.11.0", true), ("0.12.0", true), ("1.0.0", true),
            ("0.10.2", false), ("0.9.6", false), ("0.6.43", false),
        ]
        for (version, expected) in cases {
            XCTAssertEqual(OpenWebUIClient.mergesHistory(version: version), expected, "version \(version)")
        }
        for junk in ["wat", "", "0", "v0.11.1", "0.x"] {
            XCTAssertFalse(OpenWebUIClient.mergesHistory(version: junk), "unparseable: \(junk)")
        }
    }

    // MARK: - Withholding replies the server is still writing

    private func nodes() -> [String: [String: Any]] {
        [
            "u1": ["id": "u1", "role": "user", "content": "oi", "timestamp": 1, "parentId": NSNull()],
            "a1": ["id": "a1", "role": "assistant", "content": "resposta completa",
                   "timestamp": 2, "parentId": "u1", "done": true,
                   "output": ["texto que só o web escreve"]],
            "a2": ["id": "a2", "role": "assistant", "content": "resposta parci",
                   "timestamp": 3, "parentId": "u1", "done": false, "output": [String]()],
        ]
    }

    func testInFlightIsExactlyTheNotDoneNodes() {
        XCTAssertEqual(OpenWebUIClient.inFlightIDs(nodes()), ["a2"])
        // Nodes this client writes always carry done: true, so an absent `done`
        // (a user message) is not "in flight".
        XCTAssertFalse(OpenWebUIClient.inFlightIDs(nodes()).contains("u1"))
    }

    /// The write that protects the reply: the streaming node is left out, so the
    /// server's `{**existing, **incoming}` keeps its own copy of it.
    func testWithheldNodeIsOmittedAndFlatListIsNotRewritten() throws {
        var chat: [String: Any] = ["messages": [["id": "u1"], ["id": "a1"]]]
        var history: [String: Any] = [:]
        let all = nodes()
        OpenWebUIClient.store(history: &history, nodes: all, currentId: "a1",
                              chat: &chat, chain: [all["a1"]!, all["u1"]!],
                              inFlight: ["a2"])

        let sent = try XCTUnwrap(chat["history"] as? [String: Any])
        let sentNodes = try XCTUnwrap(sent["messages"] as? [String: [String: Any]])
        XCTAssertNil(sentNodes["a2"], "a reply still streaming must not be written back")
        XCTAssertNotNil(sentNodes["a1"])
        XCTAssertEqual(sent["currentId"] as? String, "a1")
        // `messages` is replaced wholesale server-side, so a payload missing a node
        // must not carry a flat projection at all.
        XCTAssertNil(chat["messages"], "flat list must be dropped when a node is withheld")
    }

    /// With nothing in flight the payload is complete — including the flat list,
    /// which is what pre-0.11 servers rely on entirely.
    func testNothingWithheldSendsTheWholeGraph() throws {
        var chat: [String: Any] = [:]
        var history: [String: Any] = [:]
        let all = nodes()
        OpenWebUIClient.store(history: &history, nodes: all, currentId: "a1",
                              chat: &chat, chain: [all["a1"]!, all["u1"]!], inFlight: [])

        let sent = try XCTUnwrap(chat["history"] as? [String: Any])
        let sentNodes = try XCTUnwrap(sent["messages"] as? [String: [String: Any]])
        XCTAssertEqual(Set(sentNodes.keys), ["u1", "a1", "a2"])
        let flat = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(flat.compactMap { $0["id"] as? String }, ["u1", "a1"], "chain is reversed to oldest-first")
    }

    /// The whole point of withholding: the server-only fields on a node the app
    /// did not create are never re-encoded through `OWMessage`.
    func testKnownNodeKeepsFieldsThisClientDoesNotModel() throws {
        var chat: [String: Any] = [:]
        var history: [String: Any] = [:]
        let all = nodes()
        OpenWebUIClient.store(history: &history, nodes: all, currentId: "a1",
                              chat: &chat, chain: [], inFlight: [])
        let sentNodes = try XCTUnwrap((chat["history"] as? [String: Any])?["messages"] as? [String: [String: Any]])
        XCTAssertEqual(sentNodes["a1"]?["output"] as? [String], ["texto que só o web escreve"])
    }

    // MARK: - Reading the server's own account of itself

    func testServerConfigDecodesTheLiveShape() throws {
        // Verbatim from https://ai.macrozao.online/api/config on 0.11.1.
        let json = Data("""
        {"status":true,"name":"Open WebUI","version":"0.11.1","default_locale":"",
         "oauth":{"providers":{},"auto_redirect":false},
         "features":{"auth":true,"auth_trusted_header":false,
         "enable_signup_password_confirmation":false,"enable_ldap":false,
         "enable_signup":true,"enable_login_form":true,"enable_websocket":true}}
        """.utf8)
        let cfg = try JSONDecoder().decode(OWServerConfig.self, from: json)
        XCTAssertEqual(cfg.version, "0.11.1")
        XCTAssertTrue(cfg.oauthProviders.isEmpty, "no providers configured means no SSO buttons")
        XCTAssertTrue(cfg.passwordLoginAvailable)
        XCTAssertFalse(cfg.ldapAvailable)
        // Absent key must not read as "off" — that would hide the tool picker on
        // every server that predates the flag.
        XCTAssertTrue(cfg.pluginsAvailable)
    }

    func testProvidersAreListedInAStableOrder() throws {
        let json = Data("""
        {"version":"0.11.1",
         "oauth":{"providers":{"oidc":"Keycloak","github":"GitHub","google":"Google"}},
         "features":{"enable_login_form":false,"enable_ldap":true,"enable_plugins":false}}
        """.utf8)
        let cfg = try JSONDecoder().decode(OWServerConfig.self, from: json)
        XCTAssertEqual(cfg.oauthProviders.map(\.key), ["github", "google", "oidc"])
        XCTAssertEqual(cfg.oauthProviders.map(\.label), ["GitHub", "Google", "Keycloak"])
        XCTAssertFalse(cfg.passwordLoginAvailable, "a server with the form off must not show it")
        XCTAssertTrue(cfg.ldapAvailable)
        XCTAssertFalse(cfg.pluginsAvailable)
    }
}

/// The device hands us a full BCP-47 tag; picking the wrong `.lproj` from it is
/// invisible until someone reads the app in the wrong script.
final class AppLanguageMatchTests: XCTestCase {

    func testScriptBeatsRegionForChinese() {
        // The bug: region was tested first, so Simplified-in-Hong-Kong and
        // Simplified-in-Macau — both real system codes — were served Traditional.
        XCTAssertEqual(AppLanguage.match("zh-Hans-HK"), .zhHans)
        XCTAssertEqual(AppLanguage.match("zh-Hans-MO"), .zhHans)
        // And the inverse holds: an explicit Traditional script wins over a
        // mainland region.
        XCTAssertEqual(AppLanguage.match("zh-Hant-CN"), .zhHant)
    }

    func testRegionStillDecidesWhenNoScriptIsGiven() {
        for code in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh-Hant-TW"] {
            XCTAssertEqual(AppLanguage.match(code), .zhHant, code)
        }
        for code in ["zh", "zh-CN", "zh-SG", "zh-Hans"] {
            XCTAssertEqual(AppLanguage.match(code), .zhHans, code)
        }
    }

    func testRegionalGermanAndLegacyCodes() {
        XCTAssertEqual(AppLanguage.match("de-AT"), .deAT)
        XCTAssertEqual(AppLanguage.match("de-CH"), .deCH)
        XCTAssertEqual(AppLanguage.match("de-DE"), .de)
        XCTAssertEqual(AppLanguage.match("pt-PT"), .ptBR, "only one Portuguese ships")
        XCTAssertEqual(AppLanguage.match("iw-IL"), .he, "legacy ISO code for Hebrew")
        XCTAssertEqual(AppLanguage.match("in-ID"), .ind, "legacy ISO code for Indonesian")
        XCTAssertNil(AppLanguage.match("xx-YY"))
    }
}

/// A picture is a picture however it was attached. Open WebUI uploads one added
/// through the file picker, the share sheet or the web UI as a *file*, so
/// matching only `type == "image"` drew a grey "image.png" pill where the photo
/// should have been.
final class AttachmentImageTests: XCTestCase {

    private func message(files: String) throws -> OWMessage {
        try JSONDecoder().decode(OWMessage.self, from: Data("""
        {"id":"m1","role":"user","content":"olha isso","files":\(files)}
        """.utf8))
    }

    func testAnUploadedPhotoIsRecognisedByEveryMarkerTheServerUses() {
        XCTAssertTrue(OWAttachment(type: "image", url: "data:image/png;base64,AA").isImage)
        XCTAssertTrue(OWAttachment(type: "file", name: "image.png").isImage)
        XCTAssertTrue(OWAttachment(type: "file", name: "FOTO.JPEG").isImage)
        XCTAssertTrue(OWAttachment(type: "file", name: "scan.HEIC").isImage)
        XCTAssertTrue(OWAttachment(type: "file", name: "sem-extensao", contentType: "image/webp").isImage)

        XCTAssertFalse(OWAttachment(type: "file", name: "relatorio.pdf").isImage)
        XCTAssertFalse(OWAttachment(type: "file", name: "notas.md").isImage)
        XCTAssertFalse(OWAttachment(type: "file", name: "arquivo").isImage)
        XCTAssertFalse(OWAttachment(type: "collection", name: "Base").isImage)
        // "pngzinho" is not a png.
        XCTAssertFalse(OWAttachment(type: "file", name: "trap.pngzinho").isImage)
    }

    /// Held by id: renders as a thumbnail through the authenticated content URL.
    func testImageFileWithOnlyAnIdIsSeparatedFromRealDocuments() throws {
        let m = try message(files: """
        [{"type":"file","id":"f1","name":"image.png"},
         {"type":"file","id":"f2","name":"relatorio.pdf"}]
        """)
        XCTAssertEqual(m.imageDocuments.map(\.id), ["f1"])
        XCTAssertEqual(m.otherDocuments.map(\.id), ["f2"])
        XCTAssertTrue(m.imageURLs.isEmpty, "no url on the record, so nothing to show directly")
    }

    /// Held by URL — the shape the web UI writes — goes straight to the image grid.
    func testImageFileWithAURLBecomesAnInlineImage() throws {
        let m = try message(files: """
        [{"type":"file","id":"f3","name":"foto.jpg","url":"/api/v1/files/f3/content",
          "content_type":"image/jpeg"}]
        """)
        XCTAssertEqual(m.imageURLs, ["/api/v1/files/f3/content"])
        XCTAssertTrue(m.imageDocuments.isEmpty)
        XCTAssertTrue(m.otherDocuments.isEmpty)
    }

    func testEveryDocumentStillReachesExactlyOneOfTheTwoLists() throws {
        let m = try message(files: """
        [{"type":"file","id":"a","name":"image.png"},
         {"type":"file","id":"b","name":"doc.pdf"},
         {"type":"collection","id":"c","name":"Base"},
         {"type":"file","name":"sem-id.png"}]
        """)
        XCTAssertEqual(m.documents.count, 4)
        XCTAssertEqual(m.imageDocuments.count + m.otherDocuments.count, m.documents.count)
        // No id means no content URL to fetch — it stays a pill rather than a
        // thumbnail that could never load.
        XCTAssertTrue(m.otherDocuments.contains { $0.name == "sem-id.png" })
    }
}

/// "Bei jedem neuen Chat neu auswählen nervt" — a new chat must not throw away
/// the model the user picked.
final class OWModelChoiceTests: XCTestCase {

    func testARememberedPickWinsOverServerOrder() {
        XCTAssertEqual(OWModelChoice.resolve(remembered: "llama3", available: ["gemma", "llama3", "qwen"]),
                       "llama3")
    }

    func testFirstModelWhenNothingWasEverPicked() {
        XCTAssertEqual(OWModelChoice.resolve(remembered: nil, available: ["gemma", "llama3"]), "gemma")
    }

    /// A model can be removed, lose its access control, or belong to a server the
    /// user has since left. Resolving to nothing would disable the composer with
    /// no explanation, so it falls back instead.
    func testAModelThisServerNoLongerOffersFallsBack() {
        XCTAssertEqual(OWModelChoice.resolve(remembered: "gone", available: ["gemma", "llama3"]), "gemma")
    }

    func testNoModelsAtAllResolvesToNothing() {
        XCTAssertNil(OWModelChoice.resolve(remembered: "llama3", available: []))
        XCTAssertNil(OWModelChoice.resolve(remembered: nil, available: []))
    }
}

/// Open WebUI has written image references three different ways, and a message
/// keeps the shape it was saved with, so all of them stay in circulation.
final class FileReferenceURLTests: XCTestCase {
    private let client = OpenWebUIClient(
        config: OWConfig(baseURL: URL(string: "https://server.example")!),
        tokens: OWKeychainStore(service: "tests.filerefs"))

    private func resolved(_ raw: String) -> String {
        client.fileReferenceURL(raw).absoluteString
    }

    /// 0.11: `fileItem.url = uploadedFile.id`, and the URL is built at render
    /// time. Resolved against the base, a bare id fetched the web app's own HTML
    /// with a 200 — the broken thumbnail.
    func testABareFileIdBecomesTheContentRoute() {
        XCTAssertEqual(resolved("2f1c8e6a-0d33-4a1b-9d2e-5b8c7a441f90"),
                       "https://server.example/api/v1/files/2f1c8e6a-0d33-4a1b-9d2e-5b8c7a441f90/content")
    }

    /// The older path returns the file's metadata JSON, not the file.
    func testTheBareFilePathGainsContent() {
        XCTAssertEqual(resolved("/api/v1/files/abc123"),
                       "https://server.example/api/v1/files/abc123/content")
        XCTAssertEqual(resolved("/api/v1/files/abc123/"),
                       "https://server.example/api/v1/files/abc123/content")
    }

    func testAContentRouteIsLeftAlone() {
        XCTAssertEqual(resolved("/api/v1/files/abc123/content"),
                       "https://server.example/api/v1/files/abc123/content")
        XCTAssertEqual(resolved("/api/v1/files/abc123/content/html"),
                       "https://server.example/api/v1/files/abc123/content/html")
    }

    func testGeneratedImagePathsStillResolveAgainstTheServer() {
        XCTAssertEqual(resolved("/cache/image/generations/9f2.png"),
                       "https://server.example/cache/image/generations/9f2.png")
    }

    func testAnAbsoluteURLIsUsedAsGiven() {
        XCTAssertEqual(resolved("https://cdn.example/pic.png"), "https://cdn.example/pic.png")
    }

    /// An id is a path segment, not a path.
    func testAnIdCannotSmugglePathSeparators() {
        XCTAssertEqual(resolved("../../admin"), "https://server.example/api/v1/files/..%2F..%2Fadmin/content")
    }
}

/// The reasoning lives in its own `output` item while `content` carries only the
/// answer. Reading `output` only when `content` was empty threw the
/// chain-of-thought away for every reply that had any text at all.
final class ReasoningDecodeTests: XCTestCase {

    private func message(_ json: String) throws -> OWMessage {
        try JSONDecoder().decode(OWMessage.self, from: Data(json.utf8))
    }

    func testReasoningSurvivesAlongsideANonEmptyContent() throws {
        let m = try message("""
        {"id":"a1","role":"assistant","content":"Para criar um vídeo UGC, siga estes passos.",
         "output":[{"type":"reasoning","content":[{"type":"output_text","text":"O usuário quer saber como criar um vídeo UGC."}]},
                   {"type":"message","content":[{"type":"output_text","text":"Para criar um vídeo UGC, siga estes passos."}]}]}
        """)
        XCTAssertEqual(m.reasoning, "O usuário quer saber como criar um vídeo UGC.")
        XCTAssertEqual(m.content, "Para criar um vídeo UGC, siga estes passos.")
    }

    /// The older shape: a web-generated reply leaves `content` empty.
    func testTextIsStillRebuiltFromOutputWhenContentIsEmpty() throws {
        let m = try message("""
        {"id":"a2","role":"assistant","content":"",
         "output":[{"type":"reasoning","content":[{"type":"output_text","text":"pensando"}]},
                   {"type":"message","content":[{"type":"output_text","text":"a resposta"}]}]}
        """)
        XCTAssertEqual(m.content, "a resposta")
        XCTAssertEqual(m.reasoning, "pensando")
    }

    /// Reasoning must never leak into the bubble.
    func testReasoningIsNotPartOfTheVisibleText() throws {
        let m = try message("""
        {"id":"a3","role":"assistant","content":"resposta",
         "output":[{"type":"reasoning","content":[{"type":"output_text","text":"segredo"}]}]}
        """)
        XCTAssertFalse(m.content.contains("segredo"))
    }
}

/// Context retrieved from a file was announced as a web search.
final class NativeSourceCardTests: XCTestCase {

    private func message(_ sources: String) throws -> OWMessage {
        try JSONDecoder().decode(OWMessage.self, from: Data("""
        {"id":"a1","role":"assistant","content":"ok","sources":\(sources)}
        """.utf8))
    }

    func testRetrievedFilesAreNamedAfterTheFileNotAsAWebSearch() throws {
        let m = try message("""
        [{"source":{"name":"SKILL.md","id":"file-1"},"document":["--- name: flow-ai-video ---"]}]
        """)
        XCTAssertEqual(m.toolUses.count, 1)
        XCTAssertEqual(m.toolUses[0].action, "files")
        XCTAssertEqual(m.toolUses[0].title, "SKILL.md")
        XCTAssertEqual(m.toolUses[0].icon, "doc.text.magnifyingglass")
        XCTAssertTrue(m.toolUses[0].results.contains("flow-ai-video"))
    }

    func testAnHTTPSourceIsStillAWebSearch() throws {
        let m = try message("""
        [{"source":{"name":"Exemplo","id":"https://exemplo.com/a"},"document":["trecho"]}]
        """)
        XCTAssertEqual(m.toolUses[0].action, "web_search")
        XCTAssertEqual(m.toolUses[0].icon, "magnifyingglass")
        XCTAssertEqual(m.toolUses[0].sources.map(\.url), ["https://exemplo.com/a"])
    }

    func testSeveralFilesAreAllNamed() throws {
        let m = try message("""
        [{"source":{"name":"SKILL.md"},"document":["a"]},
         {"source":{"name":"notas.pdf"},"document":["b"]}]
        """)
        XCTAssertEqual(m.toolUses[0].title, "SKILL.md, notas.pdf")
    }
}

/// Open WebUI emits progress while it works — `queries_generated`,
/// `sources_retrieved`, bare `web_search` pings. The web UI shows them for a
/// second; carding each one left the reply topped by permanent rows named after
/// internal events, with nothing inside them to open.
final class StatusHistoryCardTests: XCTestCase {

    private func message(_ status: String, sources: String = "[]") throws -> OWMessage {
        try JSONDecoder().decode(OWMessage.self, from: Data("""
        {"id":"a1","role":"assistant","content":"ok","statusHistory":\(status),"sources":\(sources)}
        """.utf8))
    }

    func testProgressPingsDoNotBecomeCards() throws {
        let m = try message("""
        [{"action":"queries_generated","queries":["vídeo UGC"],"done":false},
         {"action":"sources_retrieved","count":5,"done":true},
         {"action":"web_search","description":"Searching the web","done":false}]
        """)
        XCTAssertFalse(m.toolUses.contains { $0.action == "sources_retrieved" })
        XCTAssertFalse(m.toolUses.contains { $0.title == "queries_generated" })
    }

    /// The queries were the one useful thing in those pings — and the thing being
    /// discarded. They name the search now.
    func testTheGeneratedQueriesNameTheSearch() throws {
        let m = try message("""
        [{"action":"queries_generated","queries":["vídeo UGC","luz de estúdio"],"done":false},
         {"action":"sources_retrieved","count":2,"done":true}]
        """)
        XCTAssertEqual(m.toolUses.count, 1)
        XCTAssertEqual(m.toolUses[0].action, "web_search")
        XCTAssertEqual(m.toolUses[0].title, "vídeo UGC, luz de estúdio")
    }

    func testAnEntryCarryingRealResultsIsStillACard() throws {
        let m = try message("""
        [{"action":"weather","query":"São Paulo","results":"28°C"}]
        """)
        XCTAssertEqual(m.toolUses.count, 1)
        XCTAssertEqual(m.toolUses[0].title, "São Paulo")
        XCTAssertEqual(m.toolUses[0].results, "28°C")
    }

    func testQueriesAreFoldedIntoTheCardBuiltFromNativeSources() throws {
        let m = try message("""
        [{"action":"queries_generated","queries":["chevette 1985"],"done":false}]
        """, sources: """
        [{"source":{"name":"Wiki","id":"https://ex.com/a"},"document":["texto"]}]
        """)
        XCTAssertEqual(m.toolUses.count, 1)
        XCTAssertEqual(m.toolUses[0].title, "chevette 1985")
        XCTAssertEqual(m.toolUses[0].sources.count, 1)
    }

    func testNoStatusAndNoSourcesMeansNoCards() throws {
        XCTAssertTrue(try message("[]").toolUses.isEmpty)
    }
}

/// Every list failure used to become an empty list with no error, so a login
/// portal answered with 200 looked exactly like an account with nothing in it.
final class DecodeListTests: XCTestCase {
    private let client = OpenWebUIClient(config: .default,
                                         tokens: OWKeychainStore(service: "tests.decodelist"))
    private struct Row: Decodable, Equatable { var id: String }

    private func decode(_ body: String, key: String? = nil) throws -> [Row] {
        try client.decodeList(Row.self, Data(body.utf8), key: key)
    }

    // MARK: answers, not failures

    func testTheEmptyAnswersStayEmpty() throws {
        XCTAssertEqual(try decode(""), [])
        XCTAssertEqual(try decode("   \n "), [])
        XCTAssertEqual(try decode("[]"), [])
        XCTAssertEqual(try decode("{}", key: "data"), [])
        // 0.11 answers 200 `null` from the image routes on real paths.
        XCTAssertEqual(try decode("null"), [])
    }

    func testABareArrayDecodes() throws {
        XCTAssertEqual(try decode(#"[{"id":"a"},{"id":"b"}]"#), [Row(id: "a"), Row(id: "b")])
    }

    func testTheNamedWrapperDecodes() throws {
        XCTAssertEqual(try decode(#"{"data":[{"id":"a"}],"total":1}"#, key: "data"), [Row(id: "a")])
        XCTAssertEqual(try decode(#"{"items":[{"id":"z"}]}"#, key: "items"), [Row(id: "z")])
    }

    /// Older servers answered these same endpoints with a bare array.
    func testAWrappedEndpointStillAcceptsABareArray() throws {
        XCTAssertEqual(try decode(#"[{"id":"a"}]"#, key: "items"), [Row(id: "a")])
    }

    // MARK: failures that used to be silent

    /// The whole point: an auth portal's HTML, served with 200.
    func testHTMLIsAFailureNotAnEmptyList() {
        XCTAssertThrowsError(try decode("<!doctype html><html><body>Sign in</body></html>"))
    }

    func testAnObjectWhereAListWasPromisedIsAFailure() {
        XCTAssertThrowsError(try decode(#"{"detail":"nope"}"#))
    }

    func testTheNamedKeyMissingIsAFailure() {
        XCTAssertThrowsError(try decode(#"{"results":[{"id":"a"}]}"#, key: "data"))
    }

    func testAListOfSomethingElseEntirelyIsAFailure() {
        XCTAssertThrowsError(try decode(#"["a","b"]"#))
    }

    /// One exotic row must not erase the collection — that policy stays.
    func testOneUndecodableRowIsDroppedNotFatal() throws {
        XCTAssertEqual(try decode(#"[{"id":"a"},"lixo",{"id":"b"}]"#), [Row(id: "a"), Row(id: "b")])
    }

    /// The old wrapper fallback scanned `obj.values` in undefined order, and an
    /// empty array under any key decodes as `[T]` for every `T`.
    func testAnEmptyArrayUnderAnotherKeyIsNotTheAnswer() {
        XCTAssertThrowsError(try decode(#"{"errors":[],"items":[{"id":"a"}]}"#, key: "data"))
    }
}

/// A filename is written once and kept forever: the server stores it verbatim
/// and hands it back on every download.
final class MultipartFilenameTests: XCTestCase {

    private func disposition(_ filename: String) -> String {
        let form = OWMultipart()
        form.appendFile(name: "file", filename: filename, mime: "text/markdown", fileData: Data("x".utf8))
        let body = String(data: form.finalized, encoding: .utf8) ?? ""
        return body.split(separator: "\r\n").first { $0.hasPrefix("Content-Disposition:") }.map(String.init) ?? ""
    }

    /// A real name from the owner's server. Accents and spaces were never the
    /// problem — raw UTF-8 between the quotes is the native form.
    func testAccentsAndSpacesGoThroughUntouched() {
        XCTAssertTrue(disposition("SKILL - cópia.md").hasSuffix(#"filename="SKILL - cópia.md""#))
    }

    /// The real break: an unescaped quote ends the value early, and a crafted name
    /// could rename the upload to something else entirely.
    func testAQuoteIsEscapedRatherThanEndingTheValue() {
        XCTAssertTrue(disposition(#"nota"aspas".txt"#).hasSuffix(#"filename="nota\"aspas\".txt""#))
        XCTAssertTrue(disposition(#"x"; filename="OUTRO.md"#)
            .hasSuffix(#"filename="x\"; filename=\"OUTRO.md""#))
    }

    /// Backslash first, mirroring the order the server's parser unescapes in.
    func testABackslashIsDoubled() {
        XCTAssertTrue(disposition(#"tras\"#).hasSuffix(#"filename="tras\\""#))
    }

    /// There is no escape for a control character: a CRLF would end the header and
    /// kill the whole request, a lone LF would silently join the filename.
    func testControlCharactersAreReplaced() {
        let d = disposition("quebra\r\nlinha.txt")
        XCTAssertTrue(d.hasSuffix(#"filename="quebra__linha.txt""#))
        XCTAssertFalse(d.contains("\r"))
        XCTAssertFalse(d.contains("\n"))
    }

    func testAPathIsReducedToItsLastComponent() {
        XCTAssertTrue(disposition("caminho/para/foto.png").hasSuffix(#"filename="foto.png""#))
    }

    func testAnEmptyNameGetsAFallback() {
        XCTAssertTrue(disposition("").hasSuffix(#"filename="arquivo""#))
    }

    func testEmojiSurvive() {
        XCTAssertTrue(disposition("🚀💥.png").hasSuffix(#"filename="🚀💥.png""#))
    }

    /// `filename*=UTF-8''…` is forbidden here and the server's parser drops any
    /// key containing `*`; alone it would stop the part being a file at all.
    func testNoExtendedFilenameParameter() {
        XCTAssertFalse(disposition("SKILL - cópia.md").contains("filename*"))
    }
}

/// SSO (issue #13). Open WebUI runs OAuth server-side and never puts the token in
/// a URL — it lands in a cookie on the redirect to `/auth`. These are the two
/// judgements the browser flow makes about where it is.
final class OAuthFlowTests: XCTestCase {
    private let client = OpenWebUIClient(
        config: OWConfig(baseURL: URL(string: "https://server.example")!),
        tokens: OWKeychainStore(service: "tests.oauth"))

    func testTheFlowStartsAtTheServersOwnLoginRoute() {
        XCTAssertEqual(client.oauthLoginURL(provider: "oidc").absoluteString,
                       "https://server.example/oauth/oidc/login")
    }

    /// A provider key comes from the server's `/api/config`; it still gets encoded
    /// as one path segment rather than trusted into the URL.
    func testAProviderKeyCannotEscapeItsSegment() {
        XCTAssertEqual(client.oauthLoginURL(provider: "../admin").absoluteString,
                       "https://server.example/oauth/..%2Fadmin/login")
    }

    private func isEnd(_ s: String) -> Bool { client.isOAuthCompletion(URL(string: s)!) }

    func testTheEndOfTheFlowIsRecognised() {
        XCTAssertTrue(isEnd("https://server.example/auth"))
        XCTAssertTrue(isEnd("https://server.example/auth/"))
        // An admin can point WEBUI_URL at a different origin; the path still ends it.
        XCTAssertTrue(isEnd("https://outro.example/auth"))
        XCTAssertTrue(isEnd("https://server.example/auth?error=x"))
        // A server mounted under a sub-path — but only on the server's own host.
        XCTAssertTrue(isEnd("https://server.example/openwebui/auth"))
    }

    /// The bug this test exists for: Google's authorization endpoint is
    /// `/o/oauth2/v2/auth`, which ends in `/auth`. Treating that as the end of the
    /// flow cancelled the navigation on the way *out*, looked for a session cookie
    /// on Google's domain, found none, and reported failure — so signing in with
    /// Google could never work.
    func testAnIdentityProvidersOwnAuthPathIsNotTheEnd() {
        XCTAssertFalse(isEnd("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&state=y"))
        XCTAssertFalse(isEnd("https://login.microsoftonline.com/common/oauth2/v2.0/auth"))
        XCTAssertFalse(isEnd("https://keycloak.example/realms/main/protocol/openid-connect/auth"))
        XCTAssertFalse(isEnd("https://idp.example/openwebui/auth"))
    }

    func testTheIdentityProvidersOwnPagesAreNotTheEnd() {
        XCTAssertFalse(isEnd("https://idp.example/authorize"))
        XCTAssertFalse(isEnd("https://server.example/oauth/oidc/login"))
        XCTAssertFalse(isEnd("https://server.example/oauth/oidc/login/callback"))
    }

    func testAFailedFlowCarriesItsReason() {
        let url = URL(string: "https://server.example/auth?error=Account%20not%20found")!
        XCTAssertEqual(OpenWebUIClient.oauthError(in: url), "Account not found")
        XCTAssertNil(OpenWebUIClient.oauthError(in: URL(string: "https://server.example/auth")!))
        XCTAssertNil(OpenWebUIClient.oauthError(in: URL(string: "https://server.example/auth?error=")!))
    }
}

/// The login screen draws itself from `/api/config`, so a server with nothing
/// configured shows exactly what it shows today.
final class ServerConfigDiscoveryTests: XCTestCase {

    private func config(_ json: String) throws -> OWServerConfig {
        try JSONDecoder().decode(OWServerConfig.self, from: Data(json.utf8))
    }

    /// The owner's server, right now.
    func testNoProvidersConfiguredMeansNoButtons() throws {
        let c = try config(#"""
        {"name":"Open WebUI","version":"0.11.1",
         "oauth":{"providers":{},"auto_redirect":false},
         "features":{"auth":true,"enable_ldap":false,"enable_login_form":true}}
        """#)
        XCTAssertTrue(c.oauthProviders.isEmpty)
        XCTAssertFalse(c.ldapAvailable)
        XCTAssertTrue(c.passwordLoginAvailable)
        XCTAssertEqual(c.version, "0.11.1")
    }

    func testProvidersAreListedInAStableOrder() throws {
        let c = try config(#"{"oauth":{"providers":{"oidc":"Authentik","github":"GitHub"}}}"#)
        XCTAssertEqual(c.oauthProviders.map(\.key), ["github", "oidc"])
        XCTAssertEqual(c.oauthProviders.map(\.label), ["GitHub", "Authentik"])
    }

    /// A server can turn the password form off and leave only SSO.
    func testPasswordLoginCanBeOff() throws {
        let c = try config(#"{"features":{"enable_login_form":false,"enable_ldap":true}}"#)
        XCTAssertFalse(c.passwordLoginAvailable)
        XCTAssertTrue(c.ldapAvailable)
    }

    /// An older server answers without these keys; nothing may disappear for it.
    func testAnOlderServerKeepsTheDefaults() throws {
        let c = try config(#"{"name":"Open WebUI","version":"0.10.2"}"#)
        XCTAssertTrue(c.passwordLoginAvailable)
        XCTAssertFalse(c.ldapAvailable)
        XCTAssertTrue(c.pluginsAvailable)
        XCTAssertTrue(c.oauthProviders.isEmpty)
    }
}

/// A provider a whole country cannot reach opens onto a page that never loads.
/// The filter for that has to be narrow, or it takes working buttons away from
/// people who have no firewall in front of them.
final class SSOAvailabilityTests: XCTestCase {

    private func reachable(_ p: [String], _ country: String?, otherWaysIn: Bool = true) -> [String] {
        OWSSOAvailability.reachable(p, country: country, otherWaysIn: otherWaysIn)
    }

    func testGoogleIsDroppedInMainlandChina() {
        XCTAssertEqual(reachable(["google", "github", "oidc"], "CN"), ["github", "oidc"])
        XCTAssertEqual(reachable(["Google"], "cn", otherWaysIn: true), [])
    }

    /// Everything else that speaks Chinese has no firewall: Taiwan, Hong Kong,
    /// Macau, Singapore, Malaysia — and a Chinese speaker anywhere else.
    func testOnlyChinaFilters() {
        for country in ["TW", "HK", "MO", "SG", "MY", "US", "BR", "PT"] {
            XCTAssertEqual(reachable(["google", "github"], country), ["google", "github"], country)
        }
    }

    /// Guessing while the storefront is still unknown would hide a working button.
    func testAnUnknownCountryFiltersNothing() {
        XCTAssertEqual(reachable(["google"], nil), ["google"])
    }

    /// `feishu` is the provider built for that market; `oidc` is the user's own.
    func testTheProvidersThatDoWorkThereAreKept() {
        XCTAssertEqual(reachable(["feishu", "oidc", "microsoft", "github"], "CN"),
                       ["feishu", "oidc", "microsoft", "github"])
    }

    /// Never leave someone with no way in. A server offering only Google is being
    /// reached over a VPN already, and the same VPN carries the sign-in.
    func testTheLastWayInIsNeverTakenAway() {
        XCTAssertEqual(reachable(["google"], "CN", otherWaysIn: false), ["google"])
        // But with a password form on screen, it goes.
        XCTAssertEqual(reachable(["google"], "CN", otherWaysIn: true), [])
        // And with another provider left, it goes either way.
        XCTAssertEqual(reachable(["google", "oidc"], "CN", otherWaysIn: false), ["oidc"])
    }

    func testNoProvidersIsNotAProblem() {
        XCTAssertEqual(reachable([], "CN", otherWaysIn: false), [])
    }
}
