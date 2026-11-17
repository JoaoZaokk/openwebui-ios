import XCTest
@testable import OpenWebUIKit

/// Folders, as 0.13.3 answers them (see `OWFolder`).
final class FoldersTests: XCTestCase {
    private static let store = OWKeychainStore(service: "tests.folders")
    override func setUp() { StubTransport.reset(); Self.store.clear() }
    override func tearDown() { StubTransport.reset(); Self.store.clear() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://folders.test")!),
                        tokens: Self.store, protocolClasses: [StubTransport.self])
    }

    func testTheListHasNoInstructionAndTheByIdRouteDoes() async throws {
        StubTransport.route("/api/v1/folders",
            .json(#"[{"id":"f1","name":"Trabalho","parent_id":null,"meta":null,"is_expanded":false}]"#))
        StubTransport.route("/api/v1/folders/f1",
            .json(#"{"id":"f1","name":"Trabalho","parent_id":null,"data":{"system_prompt":"Seja breve."}}"#))
        let c = client()
        let list = try await c.folders()
        XCTAssertEqual(list.map(\.name), ["Trabalho"])
        XCTAssertNil(list[0].systemPrompt)
        let one = try await c.folder("f1")
        XCTAssertEqual(one.systemPrompt, "Seja breve.")
    }

    func testAServerWithoutFoldersIsAnEmptyList() async throws {
        StubTransport.route("/api/v1/folders", .json(#"{"detail":"Not Found"}"#, status: 404))
        let list = try await client().folders()
        XCTAssertTrue(list.isEmpty)
    }

    func testNestedFoldersKeepTheirParent() async throws {
        StubTransport.route("/api/v1/folders",
            .json(#"[{"id":"a","name":"A","parent_id":null},{"id":"b","name":"B","parent_id":"a"}]"#))
        let list = try await client().folders()
        XCTAssertEqual(list.first { $0.id == "b" }?.parentID, "a")
    }

    func testCreateSendsTheName() async throws {
        StubTransport.route("/api/v1/folders", .json(#"{"id":"n1","name":"Novo","parent_id":null}"#))
        let made = try await client().createFolder(name: "Novo")
        XCTAssertEqual(made.id, "n1")
        XCTAssertEqual(StubTransport.sentJSON("/api/v1/folders")?["name"] as? String, "Novo")
    }

    func testUpdateWritesTheInstructionAndAnEmptyOneClearsIt() async throws {
        StubTransport.route("/api/v1/folders/f1/update", .json(#"{"id":"f1","name":"T","data":{"system_prompt":"x"}}"#))
        let c = client()
        _ = try await c.updateFolder("f1", name: "T", systemPrompt: "  Responda em inglês.  ")
        var data = StubTransport.sentJSON("/api/v1/folders/f1/update")?["data"] as? [String: Any]
        XCTAssertEqual(data?["system_prompt"] as? String, "Responda em inglês.")
        _ = try await c.updateFolder("f1", name: "T", systemPrompt: "   ")
        data = StubTransport.sentJSON("/api/v1/folders/f1/update")?["data"] as? [String: Any]
        XCTAssertNotNil(data, "data is replaced whole: it must be sent, empty")
        XCTAssertNil(data?["system_prompt"])
    }

    func testMovingAChatOutSendsAnExplicitNull() async throws {
        StubTransport.route("/api/v1/chats/c1/folder", .json(#"{"id":"c1","folder_id":null}"#))
        let c = client()
        try await c.moveChat("c1", toFolder: "f1")
        XCTAssertEqual(StubTransport.sentJSON("/api/v1/chats/c1/folder")?["folder_id"] as? String, "f1")
        try await c.moveChat("c1", toFolder: nil)
        let body = StubTransport.sentJSON("/api/v1/chats/c1/folder")
        XCTAssertTrue(body?.keys.contains("folder_id") == true, "null is the request, not an omission")
        XCTAssertTrue(body?["folder_id"] is NSNull)
    }

    func testChatsInAFolderAreStampedWithIt() async throws {
        StubTransport.route("/api/v1/chats/folder/f1",
            .json(#"[{"id":"c1","title":"Ata","updated_at":10,"created_at":9,"archived":false,"pinned":false}]"#))
        let rows = try await client().chats(inFolder: "f1")
        XCTAssertEqual(rows.first?.folderID, "f1")
    }

    func testTheCompletionCarriesTheFolderSoTheServerAppliesItsInstruction() throws {
        let c = client()
        let comp = ChatCompletionsClient(client: c)
        let withFolder = try comp.buildRequest(model: "m", messages: [], files: [],
                                               options: OWStreamOptions(folderID: "f1"))
        let json = try JSONSerialization.jsonObject(with: withFolder.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["folder_id"] as? String, "f1")
        let without = try comp.buildRequest(model: "m", messages: [], files: [], options: OWStreamOptions())
        let plain = try JSONSerialization.jsonObject(with: without.httpBody ?? Data()) as? [String: Any]
        XCTAssertNil(plain?["folder_id"])
    }

    /// Report from 1.14: "moving a chat to a folder works, but the chat shows up
    /// duplicated — in the folder and in the full list; on the web it does not".
    /// The main list asked for `include_folders=true`, a workaround from before
    /// the app had any folder UI, and it kept returning every foldered chat.
    func testTheMainListDoesNotAskForFolderedChats() async throws {
        StubTransport.route("/api/v1/chats", .json("[]"))
        _ = try await client().chats()
        let queries = StubTransport.seenQueries["/api/v1/chats"] ?? []
        XCTAssertEqual(queries.count, 1)
        XCTAssertFalse(queries[0].contains("include_folders"), "asked for: \(queries[0])")
    }
}
