import XCTest
@testable import OpenWebUIKit

final class OWConfigTests: XCTestCase {
    func testURLKeepsQueryString() {
        let cfg = OWConfig(baseURL: URL(string: "https://openwebui.example.com")!)
        XCTAssertEqual(cfg.url("/api/v1/chats/?page=2").absoluteString,
                       "https://openwebui.example.com/api/v1/chats/?page=2")
    }

    func testURLResolvesSimplePath() {
        let cfg = OWConfig.default
        XCTAssertEqual(cfg.url("/api/models").absoluteString,
                       "https://openwebui.example.com/api/models")
    }

    func testNormalizeAddsHTTPS() {
        XCTAssertEqual(OWConfig.normalize("openwebui.example.com")?.absoluteString,
                       "https://openwebui.example.com")
        XCTAssertEqual(OWConfig.normalize("http://10.0.0.5:8080/")?.absoluteString,
                       "http://10.0.0.5:8080")
        XCTAssertNil(OWConfig.normalize(""))
    }

    func testChatSummaryDecodesEpochTimestamps() throws {
        let json = #"{"id":"abc","title":"Oi","updated_at":1750000000,"created_at":1749000000}"#
        let s = try JSONDecoder().decode(OWChatSummary.self, from: Data(json.utf8))
        XCTAssertEqual(s.id, "abc")
        XCTAssertEqual(s.title, "Oi")
        XCTAssertEqual(s.updatedAt, 1_750_000_000)
    }

    func testChatFlattensNestedMessages() throws {
        let json = """
        {"id":"c1","title":"Top","chat":{"title":"Top","models":["llama3"],
         "messages":[{"id":"m1","role":"user","content":"oi","timestamp":1},
                     {"id":"m2","role":"assistant","content":"olá","timestamp":2}]}}
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        XCTAssertEqual(chat.models, ["llama3"])
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.role, .assistant)
    }
}
