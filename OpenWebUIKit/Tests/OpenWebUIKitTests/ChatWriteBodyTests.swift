import XCTest
@testable import OpenWebUIKit

/// What actually goes on the wire when this client saves a conversation, on a
/// server that merges `history` by message id (0.11+) and on one that replaces
/// the whole blob (0.10 and earlier).
///
/// `mergesHistoryServerSide` feeds three expressions — `syncChat`,
/// `syncChatTree` and `renameChat` — and until now only the version algebra was
/// tested. The algebra being right does not prove it is wired to anything, and
/// the two failure modes are not symmetric: withholding a node on 0.11
/// *preserves* the server's copy, while the same omission on 0.10 **deletes the
/// message**. That is the whole reason the gate exists, so the assertions here
/// are on the bytes, not on the boolean.
final class ChatWriteBodyTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.chatwrite")
    private static let chatPath = "/api/v1/chats/chat-1"

    /// `GET /api/v1/chats/{id}` as 0.11 answers it while someone else is
    /// streaming a reply: `a1` carries `done: false` and a truncated `content`,
    /// which is the overlay `overlay_response_streams` puts on top of the stored
    /// row. Writing that node back is what pinned the truncated text into the
    /// database.
    private static let chatJSON = """
    {"id":"chat-1","title":"Antiga","chat":{
      "title":"Antiga","models":["m"],"params":{},"tags":[],"timestamp":1000,
      "history":{"messages":{
        "u1":{"id":"u1","role":"user","content":"oi","timestamp":1,
              "parentId":null,"childrenIds":["a1"]},
        "a1":{"id":"a1","role":"assistant","content":"resposta parci","timestamp":2,
              "parentId":"u1","childrenIds":[],"done":false,"output":[]}},
       "currentId":"a1"},
      "messages":[{"id":"u1","role":"user","content":"oi","timestamp":1},
                  {"id":"a1","role":"assistant","content":"resposta parci","timestamp":2}]}}
    """

    override func setUp() {
        super.setUp()
        StubTransport.reset()
        store.clear()
    }

    override func tearDown() {
        StubTransport.reset()
        store.clear()
        super.tearDown()
    }

    /// The chat as the merge sees it: the inner object, unwrapped from the
    /// envelope the server puts it in.
    private func serverChat() throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(Self.chatJSON.utf8)) as? [String: Any]
        return try XCTUnwrap(obj?["chat"] as? [String: Any])
    }

    /// A turn the server has never seen. Without one, `mergeTree` finds nothing
    /// added and returns false, and `syncChatTree` returns before it writes
    /// anything at all — every assertion below would pass vacuously.
    private func newTurn() -> OWMessage {
        var m = OWMessage(id: "u2", role: .user, content: "segunda pergunta")
        m.parentId = "a1"
        return m
    }

    private func nodes(in chat: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((chat["history"] as? [String: Any])?["messages"] as? [String: Any])
    }

    // MARK: - The merge itself

    /// Withholding is the write that protects the reply: the streaming node is
    /// left out so the server's `{**existing, **incoming}` keeps its own copy —
    /// and the flat projection goes with it, because that key *is* replaced
    /// wholesale and would contradict the graph.
    func testWithholdingLeavesTheStreamingReplyOutAndDropsTheFlatList() throws {
        var chat = try serverChat()

        XCTAssertTrue(OpenWebUIClient.mergeTree(into: &chat, tree: [newTurn()], currentId: "u2",
                                                model: "m", withholdInFlight: true))

        XCTAssertEqual(Set(try nodes(in: chat).keys), ["u1", "u2"])
        XCTAssertNil(chat["messages"], "a payload missing a node must not carry a flat projection")
    }

    /// Not withholding sends the whole graph, including the node someone else is
    /// writing. On a server that replaces the blob this is not a compromise: it
    /// is the only safe write there.
    func testWithoutWithholdingEveryNodeAndTheFlatListAreSent() throws {
        var chat = try serverChat()

        XCTAssertTrue(OpenWebUIClient.mergeTree(into: &chat, tree: [newTurn()], currentId: "u2",
                                                model: "m", withholdInFlight: false))

        XCTAssertEqual(Set(try nodes(in: chat).keys), ["u1", "a1", "u2"])
        let flat = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(flat.compactMap { $0["id"] as? String }, ["u1", "a1", "u2"],
                       "the flat list is the active branch, oldest first")
    }

    // MARK: - The same merge, wired to a server

    /// - Parameter version: what `/api/config` answers. `nil` routes it nowhere,
    ///   which is the case that matters most — a server whose version could not
    ///   be read must be treated as one that deletes.
    private func makeClient(version: String?) -> OpenWebUIClient {
        if let version {
            StubTransport.route("/api/config", .json(#"{"version":"\#(version)"}"#))
        }
        // One route serves both the GET and the POST: the stub keys on path, and
        // `syncChatTree` throws the POST's response away.
        StubTransport.route(Self.chatPath, .json(Self.chatJSON))
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://merge.test")!),
                               tokens: store, protocolClasses: [StubTransport.self])
    }

    private func sentChat() throws -> [String: Any] {
        try XCTUnwrap(StubTransport.sentJSON(Self.chatPath)?["chat"] as? [String: Any])
    }

    func testOn011TheStreamingNodeIsOmittedFromWhatIsPosted() async throws {
        let client = makeClient(version: "0.11.1")

        try await client.syncChatTree(id: "chat-1", title: "Antiga", models: ["m"],
                                      tree: [newTurn()], currentId: "u2")

        let chat = try sentChat()
        XCTAssertEqual(Set(try nodes(in: chat).keys), ["u1", "u2"],
                       "on a merging server, omitting the in-flight reply preserves it")
        XCTAssertNil(chat["messages"])
    }

    func testOn010TheWholeGraphIsPostedBecauseOmittingWouldDelete() async throws {
        let client = makeClient(version: "0.10.6")

        try await client.syncChatTree(id: "chat-1", title: "Antiga", models: ["m"],
                                      tree: [newTurn()], currentId: "u2")

        let chat = try sentChat()
        XCTAssertEqual(Set(try nodes(in: chat).keys), ["u1", "a1", "u2"],
                       "this server replaces the blob — a node left out is a node deleted")
        let flat = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(flat.compactMap { $0["id"] as? String }, ["u1", "a1", "u2"])
    }

    /// `/api/config` unreachable, so the version is never learned. The gate has
    /// to fall to the behaviour that cannot lose data, not to the newer one.
    func testAnUnreadableVersionIsTreatedAsAServerThatDeletes() async throws {
        let client = makeClient(version: nil)

        try await client.syncChatTree(id: "chat-1", title: "Antiga", models: ["m"],
                                      tree: [newTurn()], currentId: "u2")

        XCTAssertNil(client.serverVersion, "the fixture was supposed to leave the version unknown")
        XCTAssertEqual(Set(try nodes(in: try sentChat()).keys), ["u1", "a1", "u2"])
    }

    // MARK: - Renaming

    /// On 0.11 a rename is a partial patch. That is not only fewer bytes: the
    /// server bumps `updated_at` only for a write carrying `history` or
    /// `messages`, so the old round-trip jumped the chat to the top of the list —
    /// and, worse, sent back the overlaid copy of a reply still being streamed.
    func testRenamingOn011SendsTheTitleAloneAndNeverReadsTheChat() async throws {
        let client = makeClient(version: "0.11.1")

        try await client.renameChat("chat-1", to: "Nome novo")

        XCTAssertEqual(try XCTUnwrap(StubTransport.sentJSON(Self.chatPath))["chat"] as? [String: String],
                       ["title": "Nome novo"])
        // `ensureServerInfo` puts a GET of /api/config into `seen` first, so count
        // only this endpoint: one hit means the POST and nothing else.
        XCTAssertEqual(StubTransport.seen.filter { $0 == Self.chatPath }.count, 1,
                       "a rename on a merging server must not round-trip the conversation")
    }

    /// On an older server the only safe rename is still fetch → patch the title →
    /// write the whole thing back, because everything left out would be dropped.
    func testRenamingOn010FetchesFirstAndWritesThePreservedBlob() async throws {
        let client = makeClient(version: "0.10.6")

        try await client.renameChat("chat-1", to: "Nome novo")

        XCTAssertEqual(StubTransport.seen.filter { $0 == Self.chatPath }.count, 2, "GET then POST")
        let chat = try sentChat()
        XCTAssertEqual(chat["title"] as? String, "Nome novo")
        XCTAssertEqual(chat["models"] as? [String], ["m"])
        XCTAssertEqual(Set(try nodes(in: chat).keys), ["u1", "a1"],
                       "the conversation rides along untouched — omitting it would erase it")
    }
}
