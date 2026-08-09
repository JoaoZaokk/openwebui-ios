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

    /// Open WebUI >= 0.10 persists assistant replies ONLY as structured
    /// `output` items — flat content stays "". Text must be reconstructed.
    func testEmptyContentReconstructedFromOutputItems() throws {
        let json = """
        {
          "id": "c4", "title": "t",
          "chat": {
            "history": {
              "currentId": "b",
              "messages": {
                "a": { "id": "a", "parentId": null, "childrenIds": ["b"],
                       "role": "user", "content": "oi", "timestamp": 1 },
                "b": { "id": "b", "parentId": "a", "childrenIds": [],
                       "role": "assistant", "content": "", "timestamp": 2, "done": true,
                       "output": [
                         { "type": "reasoning", "content": [ {"type": "reasoning_text", "text": "hmm"} ] },
                         { "type": "message", "content": [
                             {"type": "output_text", "text": "Olá! "},
                             {"type": "output_text", "text": "Tudo bem?"} ] }
                       ] }
              }
            }
          }
        }
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        XCTAssertEqual(chat.messages.last?.content, "Olá! Tudo bem?")
    }

    /// Web-search citations decode from the server `sources` shape (and from
    /// the SSE frame, which shares it) into deduplicated OWWebSource values.
    func testSourcesDecodeAndSSEFrame() throws {
        let entry = """
        [ { "source": { "name": "Wikipedia" },
            "document": ["…"],
            "metadata": [ {"source": "https://pt.wikipedia.org/wiki/Chevette"},
                          {"source": "https://pt.wikipedia.org/wiki/Chevette"} ] },
          { "source": { "name": "not-a-url" }, "metadata": [ null ] } ]
        """
        let msgJSON = """
        { "id": "m", "role": "assistant", "content": "resp", "timestamp": 1,
          "sources": \(entry) }
        """
        let m = try JSONDecoder().decode(OWMessage.self, from: Data(msgJSON.utf8))
        XCTAssertEqual(m.sources.map(\.url), ["https://pt.wikipedia.org/wiki/Chevette", nil])
        XCTAssertEqual(m.sources.map(\.name), ["Wikipedia", "not-a-url"])

        let frame = try JSONDecoder().decode(OWSourcesFrame.self,
                                             from: Data("{\"sources\": \(entry)}".utf8))
        XCTAssertEqual(frame.webSources.first?.url, "https://pt.wikipedia.org/wiki/Chevette")
    }

    /// Delta content as an array of parts (some pipes) must not be dropped,
    /// and error frames may carry a plain string.
    func testChunkFlexibleShapes() throws {
        let parts = """
        { "choices": [ { "delta": { "content": [ {"type": "text", "text": "abc"} ] } } ] }
        """
        let c1 = try JSONDecoder().decode(OWCompletionChunk.self, from: Data(parts.utf8))
        XCTAssertEqual(c1.choices?.first?.delta?.content, "abc")

        let strErr = try JSONDecoder().decode(OWCompletionChunk.self,
                                              from: Data("{\"error\": \"boom\"}".utf8))
        XCTAssertEqual(strErr.errorMessage, "boom")

        let full = """
        { "choices": [ { "message": { "content": "resposta inteira" } } ] }
        """
        let f = try JSONDecoder().decode(OWFullCompletion.self, from: Data(full.utf8))
        XCTAssertEqual(f.text, "resposta inteira")
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

    /// A thinking model persists its chain-of-thought inline as a leading
    /// <think>…</think> block; decode must lift it into `reasoning` and leave the
    /// visible reply clean (no raw tags leaking into the bubble).
    func testInlineThinkBlockSplitsIntoReasoning() throws {
        let json = """
        {
          "id": "c4", "title": "t",
          "chat": {
            "messages": [
              { "id": "a", "role": "assistant", "timestamp": 1,
                "content": "<think>Let me weigh the options.</think>The answer is 42." }
            ]
          }
        }
        """
        let chat = try JSONDecoder().decode(OWChat.self, from: Data(json.utf8))
        let m = try XCTUnwrap(chat.messages.first)
        XCTAssertEqual(m.reasoning, "Let me weigh the options.")
        XCTAssertEqual(m.content, "The answer is 42.")
    }

    /// An unclosed <think> (chat still generating when it was persisted) counts as
    /// all-reasoning rather than dumping raw tags into the reply.
    func testUnclosedThinkIsAllReasoning() {
        let split = OWMessage.splitReasoning("<think>still thinking")
        XCTAssertEqual(split.content, "")
        XCTAssertEqual(split.reasoning, "still thinking")
    }

    /// A plain reply with no think block is returned untouched.
    func testNoThinkBlockUnchanged() {
        let split = OWMessage.splitReasoning("Just a normal answer.")
        XCTAssertEqual(split.content, "Just a normal answer.")
        XCTAssertEqual(split.reasoning, "")
    }

    /// The offline cache encodes an OWMessage and decodes it back — reasoning and
    /// web-search citations must survive that round-trip (they live in fields the
    /// server shapes differently).
    func testCacheRoundTripKeepsReasoningAndSources() throws {
        var m = OWMessage(role: .assistant, content: "resposta", model: "x",
                          timestamp: 1, reasoning: "pensando…")
        m.sources = [OWWebSource(name: "Wikipedia", url: "https://pt.wikipedia.org/wiki/Chevette")]
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(OWMessage.self, from: data)
        XCTAssertEqual(back.content, "resposta")
        XCTAssertEqual(back.reasoning, "pensando…")
        XCTAssertEqual(back.sources.map(\.url), ["https://pt.wikipedia.org/wiki/Chevette"])
        XCTAssertEqual(back.sources.first?.name, "Wikipedia")
    }
}
