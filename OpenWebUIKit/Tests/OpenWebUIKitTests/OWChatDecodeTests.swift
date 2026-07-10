import XCTest
@testable import OpenWebUIKit

/// Regression tests for the web↔app sync bug: chats edited on the Open WebUI
/// web app (image generations, tool calls) must decode fully — one odd message
/// must never drop the rest, and the history graph must order like the web UI.
final class OWChatDecodeTests: XCTestCase {

    /// Web-created chat: flat `messages` untouched (stale) while `history` has
    /// the full branch, including an assistant message whose image lives in
    /// `files` with a server-relative URL.
    func testHistoryChainWinsAndKeepsGeneratedImage() throws {
        let json = """
        {
          "id": "c1", "title": "Chevette",
          "chat": {
            "title": "Chevette",
            "models": ["mimo-v2.5"],
            "messages": [
              { "id": "m1", "role": "user", "content": "um Chevette", "timestamp": 100 }
            ],
            "history": {
              "currentId": "m4",
              "messages": {
                "m1": { "id": "m1", "parentId": null, "childrenIds": ["m2"],
                        "role": "user", "content": "um Chevette", "timestamp": 100 },
                "m2": { "id": "m2", "parentId": "m1", "childrenIds": ["m3"],
                        "role": "assistant", "model": "mimo-v2.5",
                        "content": "Ah, o clássico!", "timestamp": 110,
                        "usage": {"prompt_tokens": 10}, "statusHistory": [{"done": true}] },
                "m3": { "id": "m3", "parentId": "m2", "childrenIds": ["m4"],
                        "role": "user", "content": "gere a imagem", "timestamp": 120 },
                "m4": { "id": "m4", "parentId": "m3", "childrenIds": [],
                        "role": "assistant", "model": "mimo-v2.5", "content": "",
                        "timestamp": 130,
                        "files": [ { "type": "image", "url": "/cache/image/generations/x.png" } ] }
              }
            }
          }
        }
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        XCTAssertEqual(chat.messages.map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(chat.messages.last?.imageURLs, ["/cache/image/generations/x.png"])
    }

    /// One malformed entry (message that is not an object) must not nuke the
    /// rest of the conversation — lossy decode keeps the good ones.
    func testMalformedMessageDoesNotDropChat() throws {
        let json = """
        {
          "id": "c2", "title": "t",
          "chat": {
            "messages": [
              { "id": "a", "role": "user", "content": "oi", "timestamp": 1 },
              "GARBAGE-NOT-AN-OBJECT",
              { "id": "b", "role": "assistant", "content": "olá", "timestamp": 2 }
            ]
          }
        }
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        XCTAssertEqual(chat.messages.map(\.id), ["a", "b"])
    }

    /// Multimodal content array + files documents still flatten correctly.
    func testMultimodalContentAndDocs() throws {
        let json = """
        {
          "id": "c3", "title": "t",
          "chat": {
            "messages": [
              { "id": "a", "role": "user", "timestamp": 1,
                "content": [ {"type": "text", "text": "veja"},
                             {"type": "image_url", "image_url": {"url": "data:image/png;base64,xx"}} ],
                "files": [ {"type": "file", "id": "f1", "name": "doc.pdf"} ] }
            ]
          }
        }
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        let m = try XCTUnwrap(chat.messages.first)
        XCTAssertEqual(m.content, "veja")
        XCTAssertEqual(m.imageURLs, ["data:image/png;base64,xx"])
        XCTAssertEqual(m.documents.first?.id, "f1")
    }
}
