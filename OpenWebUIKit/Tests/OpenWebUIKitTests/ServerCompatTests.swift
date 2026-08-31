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
