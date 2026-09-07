import XCTest
@testable import OpenWebUIKit

/// The reader that turns `POST /api/chat/completions` into the events a chat
/// bubble is built from.
///
/// It had exactly one test — `buildRequest` — and that one never sent the
/// request. Everything after the first byte was unreachable without a live
/// server: the `[DONE]` terminator, the two spellings of a reasoning delta, the
/// web-search frame that arrives *before* the first token, the whole-body JSON
/// answer pipe models give instead of SSE, and the two refusals that are not
/// the same refusal.
final class StreamReaderTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.streamreader")
    private static let completions = "/api/chat/completions"

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

    private func signedInClient() -> OpenWebUIClient {
        store.save(token: "token-vivo")
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://stream.test")!),
                               tokens: store, protocolClasses: [StubTransport.self])
    }

    /// Reads a whole reply. `stream()` hands back an `AsyncThrowingStream`, so a
    /// refusal surfaces by throwing out of this loop, not as an update.
    private func collect(_ client: OpenWebUIClient) async throws -> [OWStreamUpdate] {
        var out: [OWStreamUpdate] = []
        let chat = ChatCompletionsClient(client: client)
        for try await update in chat.stream(model: "m",
                                            messages: [OWChatMessageInput(role: "user", text: "oi")]) {
            out.append(update)
        }
        return out
    }

    /// `OWStreamUpdate` is not `Equatable` and does not need to be: what these
    /// tests assert is the *sequence*, so each update is flattened to its case
    /// plus its payload and the whole reply compared in one line.
    private func tags(_ updates: [OWStreamUpdate]) -> [String] {
        updates.map { u in
            switch u {
            case .textDelta(let t):      return "text(\(t))"
            case .reasoningDelta(let r): return "reasoning(\(r))"
            case .sources(let s):        return "sources(\(s.map(\.name).joined(separator: ",")))"
            case .error(let e):          return "error(\(e))"
            case .done:                  return "done"
            }
        }
    }

    // MARK: - The SSE path

    /// The ordinary reply: tokens in the order they were sent, and `[DONE]`
    /// becoming the one event that tells the UI the bubble is finished.
    func testTokensArriveInOrderAndDONEClosesTheReply() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"content":"Oi"}}]}"#,
            #"{"choices":[{"delta":{"content":", tudo"}}]}"#,
            #"{"choices":[{"delta":{"content":" bem?"}}]}"#,
            "[DONE]",
        ]))

        let updates = try await collect(signedInClient())

        XCTAssertEqual(tags(updates), ["text(Oi)", "text(, tudo)", "text( bem?)", "done"])
    }

    /// Two providers, two spellings of the same thing. Reading only one of them
    /// dropped the chain-of-thought disclosure for every model that used the
    /// other, with no error anywhere to say so.
    func testBothSpellingsOfAReasoningDeltaAreRead() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"reasoning":"pensando"}}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"ainda pensando"}}]}"#,
            #"{"choices":[{"delta":{"content":"42"}}]}"#,
            "[DONE]",
        ]))

        let updates = try await collect(signedInClient())

        XCTAssertEqual(tags(updates),
                       ["reasoning(pensando)", "reasoning(ainda pensando)", "text(42)", "done"])
    }

    /// The web-search citations arrive in a frame with no `choices` key at all,
    /// ahead of the first token — so the reader cannot treat "not a chunk" as
    /// "skip", which is what it used to do.
    func testTheSourcesFrameArrivesBeforeTheFirstToken() async throws {
        StubTransport.route(Self.completions, .sse([
            #"""
            {"sources":[{"source":{"name":"Wikipédia"},
              "document":[],
              "metadata":[{"source":"https://pt.wikipedia.org/wiki/Teste"}]}]}
            """#.replacingOccurrences(of: "\n", with: ""),
            #"{"choices":[{"delta":{"content":"resposta"}}]}"#,
            "[DONE]",
        ]))

        let updates = try await collect(signedInClient())

        XCTAssertEqual(tags(updates), ["sources(Wikipédia)", "text(resposta)", "done"])
        guard case .sources(let srcs) = updates[0] else { return XCTFail("not a sources update") }
        XCTAssertEqual(srcs.first?.url, "https://pt.wikipedia.org/wiki/Teste")
    }

    /// An error mid-stream ends the reply. There is no `[DONE]` after it — the
    /// server stops talking — so the reader has to close the stream itself.
    func testAnErrorFrameEndsTheStream() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"content":"come"}}]}"#,
            #"{"error":{"message":"o modelo saiu do ar"}}"#,
            #"{"choices":[{"delta":{"content":"nunca chega"}}]}"#,
        ]))

        let updates = try await collect(signedInClient())

        XCTAssertEqual(tags(updates), ["text(come)", "error(o modelo saiu do ar)"],
                       "frames after the error must not be read")
    }

    // MARK: - The whole-body JSON answer

    /// Pipe and function models, filters, and some providers answer HTTP 200
    /// with one complete JSON body instead of an event stream. Reading it as SSE
    /// found no `data:` line and rendered "(sem resposta)" over a perfectly good
    /// answer — the Content-Type is the only thing that distinguishes them.
    func testAJSONContentTypeTakesTheWholeBodyPath() async throws {
        StubTransport.route(Self.completions,
                            .json(#"{"choices":[{"message":{"content":"resposta inteira"}}]}"#))

        let updates = try await collect(signedInClient())

        XCTAssertEqual(tags(updates), ["text(resposta inteira)", "done"])
    }

    func testAFullCompletionBodyBecomesOneDeltaAndADone() async throws {
        let updates = try await drainJSONCompletion(
            #"{"choices":[{"message":{"content":"tudo de uma vez"}}]}"#)
        XCTAssertEqual(tags(updates), ["text(tudo de uma vez)", "done"])
    }

    /// 0.6.x answers its error path with HTTP 200 and a literal `null`. There is
    /// nothing in it to render and nothing to apologise with, so the reader
    /// supplies the only sentence it can — and no `.done`, because nothing
    /// completed.
    func testALiteralNullBodyBecomesTheGenericFailureAndNothingElse() async throws {
        let updates = try await drainJSONCompletion("null")
        XCTAssertEqual(tags(updates), ["error(\(L("Falha ao iniciar o stream")))"])
    }

    private func drainJSONCompletion(_ body: String) async throws -> [OWStreamUpdate] {
        let (stream, continuation) = AsyncThrowingStream<OWStreamUpdate, Error>.makeStream()
        ChatCompletionsClient.yieldJSONCompletion(body, into: continuation)
        continuation.finish()
        var out: [OWStreamUpdate] = []
        for try await u in stream { out.append(u) }
        return out
    }

    func testTheSentenceARefusalTurnsInto() {
        XCTAssertEqual(ChatCompletionsClient.extractError(#"{"detail":"Model not allowed"}"#),
                       "Model not allowed")
        XCTAssertEqual(ChatCompletionsClient.extractError(#"{"message":"upstream down"}"#), "upstream down")
        XCTAssertEqual(ChatCompletionsClient.extractError(#"{"error":"no credit"}"#), "no credit")
        // Not JSON at all: a proxy's plain text is still what happened.
        XCTAssertEqual(ChatCompletionsClient.extractError("502 Bad Gateway"), "502 Bad Gateway")
        XCTAssertNil(ChatCompletionsClient.extractError(""))
        XCTAssertNil(ChatCompletionsClient.extractError(String(repeating: "x", count: 300)),
                     "a whole HTML page is not a sentence to show a user")
    }

    // MARK: - The two refusals

    /// A 403 here is the server refusing *this model* to this account. Its own
    /// `detail` is the only thing that says which, and it has to reach the caller
    /// intact rather than being flattened into "start failed".
    func testA403NamesTheModelItRefused() async {
        StubTransport.route(Self.completions,
                            .json(#"{"detail":"model not allowed"}"#, status: 403))
        let client = signedInClient()

        let err = await owError { try await self.collect(client) }
        guard case .http(let code, let detail)? = err else {
            return XCTFail("expected .http, got \(String(describing: err))")
        }
        XCTAssertEqual(code, 403)
        XCTAssertEqual(detail, "model not allowed")
    }

    /// A 401 here ends the session exactly as it does on every other route.
    ///
    /// It did not, until the hop was called by hand: `stream` holds
    /// `longSession` directly and never passes through `send`, so the one
    /// request a user makes most often was the single route that reported a dead
    /// session and then kept it — the token stayed in memory and in the
    /// Keychain, `isAuthenticated` stayed true, and nothing told the app to
    /// route back to login.
    func testA401OnTheStreamEndsTheSessionLikeEveryOtherRoute() async {
        StubTransport.route(Self.completions,
                            .json(#"{"detail":"Not authenticated"}"#, status: 401))
        let client = signedInClient()
        let ended = XCTNSNotificationExpectation(name: OpenWebUIClient.sessionEndedNotification)

        let err = await owError { try await self.collect(client) }
        guard case .notAuthenticated? = err else {
            return XCTFail("expected .notAuthenticated, got \(String(describing: err))")
        }

        XCTAssertNil(client.token)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(store.loadToken(), "a token the server rejected must not survive a relaunch")
        await fulfillment(of: [ended], timeout: 1)
    }
}
