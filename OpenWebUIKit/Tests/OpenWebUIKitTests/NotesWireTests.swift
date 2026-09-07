import XCTest
@testable import OpenWebUIKit

/// What the two notes routes actually hand back, and why only one of them may
/// ever be edited.
///
/// `GET /api/v1/notes/` runs every note through
/// `_truncate_note_data(data, max_length=1000)` (backend routers/notes.py:42) —
/// the same on the `/pinned` list, and unchanged from 0.9.6 through 0.11.3. It
/// also answers with `NoteItemResponse`, which has no `access_grants`. The by-id
/// route answers the whole `NoteModel`: full body, grants included.
///
/// That matters because `POST /{id}/update` shallow-merges what it is sent over
/// the stored `data` — `note.data = {**(note.data or {}), **(form_data['data']
/// or {})}` (models/notes.py:354) — so `content` is replaced entire. Sending the
/// listed body back is not a no-op edit: it is the first 1000 characters
/// overwriting the note. Everything below pins that difference.
final class NotesWireTests: XCTestCase {

    private static let store = OWKeychainStore(service: "tests.notes")

    override func setUp() {
        StubTransport.reset()
        Self.store.clear()
    }

    override func tearDown() {
        StubTransport.reset()
        Self.store.clear()
    }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://notes.test")!),
                        tokens: Self.store,
                        protocolClasses: [StubTransport.self])
    }

    // MARK: - The bodies

    /// 2400 characters of varied ASCII: no quote, backslash or newline, so it
    /// drops into a JSON literal as-is, and no two slices of it are equal.
    private static let wholeBody: String = {
        var s = ""
        var i = 0
        while s.count < 2400 { s += "paragrafo \(i) do corpo da nota; "; i += 1 }
        return String(s.prefix(2400))
    }()

    /// Exactly what `_truncate_note_data` leaves of it.
    private static let listedBody = String(wholeBody.prefix(1000))

    private static let grant = OWAccessGrant(id: "g1", principal_type: "user",
                                             principal_id: "u2", permission: "write")

    /// `NoteItemResponse`: truncated `data`, and no `access_grants` key at all.
    private static var listJSON: String {
        """
        [{"id":"n1","title":"Ata longa",
          "data":{"content":{"md":"\(listedBody)"}},
          "is_pinned":false,
          "updated_at":1756600000000000000,"created_at":1756500000000000000}]
        """
    }

    /// `NoteResponse`: the whole body, plus the grants the list dropped.
    private static var byIdJSON: String {
        """
        {"id":"n1","user_id":"u1","title":"Ata longa",
         "data":{"content":{"md":"\(wholeBody)"}},"meta":null,
         "is_pinned":false,
         "access_grants":[{"id":"g1","principal_type":"user","principal_id":"u2","permission":"write"}],
         "updated_at":1756600000000000000,"created_at":1756500000000000000}
        """
    }

    /// `URL.path` drops a trailing slash, so the list route is keyed without one.
    private let listPath = "/api/v1/notes"
    private let notePath = "/api/v1/notes/n1"
    private let updatePath = "/api/v1/notes/n1/update"

    // MARK: - Tests

    func testTheListIsCutAtAThousandCharactersAndTheByIdRouteIsNot() async throws {
        StubTransport.route(listPath, .json(Self.listJSON))
        StubTransport.route(notePath, .json(Self.byIdJSON))
        let client = client()

        let listed = try await client.notes()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].markdown.count, 1000, "the list body is truncated by the server")
        XCTAssertEqual(listed[0].markdown, Self.listedBody)
        XCTAssertNil(listed[0].accessGrants, "the list response carries no access_grants")
        XCTAssertFalse(StubTransport.requested(notePath), "listing must not read notes one by one")

        let whole = try await client.note("n1")
        XCTAssertTrue(StubTransport.requested(notePath), "the by-id route is what was asked")
        XCTAssertEqual(whole.markdown.count, 2400)
        XCTAssertEqual(whole.markdown, Self.wholeBody)
        XCTAssertTrue(whole.markdown.hasPrefix(listed[0].markdown),
                      "the listed body is a prefix of the real one — which is why saving it truncates")
        XCTAssertEqual(whole.accessGrants, [Self.grant])
        XCTAssertEqual(whole.title, "Ata longa")
        XCTAssertEqual(whole.updatedAt, 1_756_600_000, "nanoseconds normalized to seconds")
    }

    func testSavingTheFetchedNoteSendsTheWholeBodyAndHandsTheGrantsBack() async throws {
        StubTransport.route(notePath, .json(Self.byIdJSON))
        StubTransport.route(updatePath, .json("{}"))
        let client = client()

        let whole = try await client.note("n1")
        try await client.updateNote(whole, title: whole.title, markdown: whole.markdown)

        let sent = try XCTUnwrap(StubTransport.sentJSON(updatePath))
        XCTAssertEqual(sent["title"] as? String, "Ata longa")
        let data = sent["data"] as? [String: Any]
        let md = (data?["content"] as? [String: Any])?["md"] as? String
        XCTAssertEqual(md?.count, 2400, "the note is saved whole, not as the list's preview")
        XCTAssertEqual(md, Self.wholeBody)

        let grants = try XCTUnwrap(sent["access_grants"] as? [[String: Any]],
                                   "omitting access_grants is what un-shares the note")
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants[0]["principal_id"] as? String, "u2")
        XCTAssertEqual(grants[0]["permission"] as? String, "write")
    }

    /// The bug, stated as a test: saving the object the list handed over sends
    /// 1000 characters and no grants, and the server's shallow merge makes that
    /// the new note. This is what the editor used to do.
    func testSavingTheListedNoteWouldTruncateItAndDropTheGrants() async throws {
        StubTransport.route(listPath, .json(Self.listJSON))
        StubTransport.route(updatePath, .json("{}"))
        let client = client()

        let listed = try await client.notes()[0]
        try await client.updateNote(listed, title: listed.title, markdown: listed.markdown)

        let sent = try XCTUnwrap(StubTransport.sentJSON(updatePath))
        let data = sent["data"] as? [String: Any]
        XCTAssertEqual(((data?["content"] as? [String: Any])?["md"] as? String)?.count, 1000)
        XCTAssertNil(sent["access_grants"],
                     "the listed note has no grants to echo, so the key is simply absent")
    }
}
