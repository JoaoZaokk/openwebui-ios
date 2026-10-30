import Foundation

/// One message in a completion request. When `imageURLs` is non-empty, the
/// content is encoded as an OpenAI-style multimodal parts array so vision models
/// (e.g. GPT-4o) can see the images.
public struct OWChatMessageInput: Encodable, Sendable {
    public var role: String
    public var text: String
    public var imageURLs: [String]

    public init(role: String, text: String, imageURLs: [String] = []) {
        self.role = role; self.text = text; self.imageURLs = imageURLs
    }
    public init(_ message: OWMessage) {
        self.role = message.role.rawValue
        self.text = message.content
        self.imageURLs = message.imageURLs
    }

    enum CodingKeys: String, CodingKey { case role, content }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if imageURLs.isEmpty {
            try c.encode(text, forKey: .content)
        } else {
            var parts: [Part] = []
            if !text.isEmpty { parts.append(Part(type: "text", text: text, image_url: nil)) }
            for url in imageURLs {
                parts.append(Part(type: "image_url", text: nil, image_url: .init(url: url)))
            }
            try c.encode(parts, forKey: .content)
        }
    }

    struct Part: Encodable {
        var type: String
        var text: String?
        var image_url: ImageURL?
        struct ImageURL: Encodable { var url: String }
    }
}

/// Tuning knobs for a completion.
public struct OWStreamOptions: Sendable {
    public var temperature: Double?
    public var webSearch: Bool
    /// Workspace tool ids the server should make callable for this reply
    /// (`/api/v1/tools/`). Forces legacy function calling — see `buildRequest`.
    public var toolIDs: [String]
    /// Declare `OWWebSearchTool` in the request's own `tools`, so the model can
    /// ask for a search. Running it is `streamReply`'s job — the server runs
    /// nothing for a request that is not from a browser tab.
    public var offerWebSearch: Bool
    public init(temperature: Double? = nil, webSearch: Bool = false, toolIDs: [String] = [],
                offerWebSearch: Bool = false) {
        self.temperature = temperature; self.webSearch = webSearch; self.toolIDs = toolIDs
        self.offerWebSearch = offerWebSearch
    }
}

/// High-level events the UI reacts to as a reply streams in.
public enum OWStreamUpdate: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    /// Web-search citations (Open WebUI prepends a `data: {"sources": …}` frame
    /// before the first token when the RAG web-search path runs).
    case sources([OWWebSource])
    /// The model asked for a function (structured `tool_calls`). Only `stream`
    /// yields it; `streamReply` acts on it instead.
    case toolCall(OWToolCall)
    /// `streamReply` is running a web search the model asked for.
    case searching([String])
    /// That search failed; the reply continues without it. The text says why.
    case searchFailed(String)
    case error(String)
    case done
}

public extension OWStreamUpdate {
    /// The provider closed the reply for length before writing a word: the
    /// conversation alone fills the model's context. Some providers (MiMo)
    /// say so this way instead of with an error.
    static let contextFull = "The conversation fills the model's context window: the reply stopped before it began (finish_reason: length)."
}

/// Streams a reply from POST /api/chat/completions. Open WebUI exposes an
/// OpenAI-compatible endpoint: newline-delimited `data: {json}` frames whose
/// `choices[0].delta.content` carries the tokens, terminated by `data: [DONE]`.
public final class ChatCompletionsClient: @unchecked Sendable {
    let client: OpenWebUIClient
    public init(client: OpenWebUIClient) { self.client = client }

    public func stream(model: String,
                       messages: [OWChatMessageInput],
                       files: [OWAttachment] = [],
                       options: OWStreamOptions = .init()) -> AsyncThrowingStream<OWStreamUpdate, Error> {
        guard messages.contains(where: { $0.role == "system" }) else {
            return attempt(model: model, messages: messages, files: files, options: options)
        }
        // Gemma through Google's API refuses the system role outright ("Developer
        // instruction is not enabled for models/gemma-…"), and the voice mode and
        // the image prompt helper both open with one — on Gemma neither produced
        // a word. One retry, with the instruction folded into the first user
        // turn, and only for that refusal and only before anything was shown.
        return AsyncThrowingStream { continuation in
            let task = Task {
                var shown = false
                do {
                    for try await update in attempt(model: model, messages: messages, files: files, options: options) {
                        if !shown, case .error(let why) = update, Self.refusesSystemRole(why) {
                            try await relay(model: model, messages: Self.foldingSystemPrompt(messages),
                                            files: files, options: options, into: continuation)
                            return
                        }
                        if case .sources = update {} else { shown = true }
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch OWError.http(_, let why?) where !shown && Self.refusesSystemRole(why) {
                    do {
                        try await relay(model: model, messages: Self.foldingSystemPrompt(messages),
                                        files: files, options: options, into: continuation)
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func relay(model: String, messages: [OWChatMessageInput], files: [OWAttachment],
                       options: OWStreamOptions,
                       into continuation: AsyncThrowingStream<OWStreamUpdate, Error>.Continuation) async throws {
        for try await update in attempt(model: model, messages: messages, files: files, options: options) {
            continuation.yield(update)
        }
        continuation.finish()
    }

    /// A provider saying it takes no system/developer instruction. Google's
    /// wording is the one met in practice; the others are the same refusal from
    /// other OpenAI-compatible hosts.
    static func refusesSystemRole(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("developer instruction is not enabled")
            || m.contains("system instruction is not enabled")
            || m.contains("system role is not supported")
            || m.contains("system messages are not supported")
            || m.contains("does not support system")
    }

    /// The system turns, joined, placed ahead of the first user turn's text.
    /// With no user turn at all they become one.
    static func foldingSystemPrompt(_ messages: [OWChatMessageInput]) -> [OWChatMessageInput] {
        let system = messages.filter { $0.role == "system" }.map(\.text).filter { !$0.isEmpty }
        var rest = messages.filter { $0.role != "system" }
        guard !system.isEmpty else { return rest }
        let instruction = system.joined(separator: "\n\n")
        if let i = rest.firstIndex(where: { $0.role == "user" }) {
            let text = rest[i].text
            rest[i].text = text.isEmpty ? instruction : instruction + "\n\n" + text
        } else {
            rest.insert(OWChatMessageInput(role: "user", text: instruction), at: 0)
        }
        return rest
    }

    private func attempt(model: String,
                         messages: [OWChatMessageInput],
                         files: [OWAttachment],
                         options: OWStreamOptions) -> AsyncThrowingStream<OWStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try buildRequest(model: model, messages: messages, files: files, options: options)
                    let (bytes, resp) = try await client.longSession.bytes(for: req)

                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Only 401 means the session is gone. A 403 here is the
                        // server refusing this model or this feature to this
                        // account — its own `detail` says which, and reporting it
                        // as an expired session hid that and sent the user to a
                        // login they did not need.
                        //
                        // `dropSession()` has to be called by hand: this path
                        // holds `longSession` directly instead of going through
                        // `send`, so nothing else runs the 401 hop. Without it
                        // the token the server just rejected stayed in memory and
                        // in the Keychain, `isAuthenticated` stayed true, and no
                        // notification went out — every screen kept retrying with
                        // a dead token while showing "Sessão expirada", and a
                        // relaunch brought it back.
                        if http.statusCode == 401 {
                            client.dropSession()
                            throw OWError.notAuthenticated
                        }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 800 { break } }
                        throw OWError.http(http.statusCode, Self.extractError(body) ?? L("Falha ao iniciar o stream"))
                    }

                    // Pipe/function models, filters and some providers answer with a
                    // single JSON body instead of SSE — render it, don't show "(sem resposta)".
                    let mime = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    if mime.contains("application/json") {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 4_000_000 { break } }
                        Self.yieldJSONCompletion(body, into: continuation)
                        continuation.finish()
                        return
                    }

                    // Structured tool calls arrive in pieces: the name in one
                    // frame, the arguments a few characters at a time after it,
                    // keyed by `index`. Yielded whole, once the stream ends.
                    var pendingCalls: [Int: (name: String, args: String)] = [:]
                    var sawDone = false
                    var produced = false
                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        let line = rawLine.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

                        if payload == "[DONE]" {
                            sawDone = true
                            break
                        }
                        guard let data = payload.data(using: .utf8) else { continue }

                        // OpenAI-style chunk, or an Open WebUI error object.
                        if let chunk = try? JSONDecoder().decode(OWCompletionChunk.self, from: data) {
                            if let err = chunk.errorMessage {
                                continuation.yield(.error(err)); break
                            }
                            if let delta = chunk.choices?.first?.delta {
                                if let r = delta.reasoning ?? delta.reasoning_content, !r.isEmpty {
                                    produced = true
                                    continuation.yield(.reasoningDelta(r))
                                }
                                if let t = delta.content, !t.isEmpty {
                                    produced = true
                                    continuation.yield(.textDelta(t))
                                }
                                if !(delta.tool_calls ?? []).isEmpty { produced = true }
                                for (n, call) in (delta.tool_calls ?? []).enumerated() {
                                    let key = call.index ?? n
                                    var c = pendingCalls[key] ?? (name: "", args: "")
                                    // Most providers send the name once; some repeat it on every piece.
                                    if let name = call.function?.name, !name.isEmpty, name != c.name { c.name += name }
                                    if let a = call.function?.arguments { c.args += a }
                                    pendingCalls[key] = c
                                }
                            }
                            if chunk.choices?.first?.finish_reason == "length", !produced {
                                continuation.yield(.error(OWStreamUpdate.contextFull)); break
                            }
                            // Not a chunk/error: maybe the prepended web-search
                            // sources frame ({"sources": [...]}, no choices key).
                            if chunk.choices == nil,
                               let frame = try? JSONDecoder().decode(OWSourcesFrame.self, from: data) {
                                let srcs = frame.webSources
                                if !srcs.isEmpty { continuation.yield(.sources(srcs)) }
                            }
                        }
                    }
                    for key in pendingCalls.keys.sorted() {
                        let c = pendingCalls[key]!
                        if !c.name.isEmpty {
                            continuation.yield(.toolCall(OWToolCall(name: c.name, arguments: c.args)))
                        }
                    }
                    if sawDone { continuation.yield(.done) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    // Internal (not private) so the tests can assert the wire format — the
    // web-search and tool gates both live in the request body and are invisible
    // from the outside otherwise.
    func buildRequest(model: String,
                      messages: [OWChatMessageInput],
                      files: [OWAttachment],
                      options: OWStreamOptions) throws -> URLRequest {
        var req = URLRequest(url: client.config.url("/api/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let t = client.token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 300
        // Open WebUI >= 0.10 only runs its server-side handlers (the RAG
        // web-search gate, and `chat_completion_tools_handler` for tool_ids) in
        // "legacy" function-calling mode; the "native" default drives tools over
        // a socket.io session we don't have, so the call would silently do
        // nothing. Harmless on older servers.
        let needsLegacy = options.webSearch || !options.toolIDs.isEmpty
        var body = try JSONEncoder().encode(
            Body(model: model, messages: messages, stream: true,
                 temperature: options.temperature, files: files.isEmpty ? nil : files,
                 tool_ids: options.toolIDs.isEmpty ? nil : options.toolIDs,
                 features: options.webSearch ? Body.Features(web_search: true) : nil,
                 params: needsLegacy ? Body.Params(function_calling: "legacy") : nil)
        )
        // A `tools` key makes the server skip its own tool resolution and pass
        // these through to the provider unchanged — which is the point: it is
        // the one tool list a request from outside a browser tab can carry.
        if options.offerWebSearch,
           var obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            obj["tools"] = [OWWebSearchTool.spec]
            body = try JSONSerialization.data(withJSONObject: obj)
        }
        req.httpBody = body
        return req
    }

    private struct Body: Encodable {
        var model: String
        var messages: [OWChatMessageInput]
        var stream: Bool
        var temperature: Double?
        var files: [OWAttachment]?
        var tool_ids: [String]?
        var features: Features?
        var params: Params?
        struct Features: Encodable { var web_search: Bool }
        struct Params: Encodable { var function_calling: String }
    }

    /// A whole-body JSON completion (non-streaming server path).
    ///
    /// Internal, not private, for the same reason `buildRequest` is: from the
    /// outside this branch is indistinguishable from the SSE one, and the two
    /// bodies that reach it — a full completion, and the literal `null` a 0.6.x
    /// error path answers 200 with — are only tellable apart by what it yields.
    static func yieldJSONCompletion(_ body: String,
                                            into c: AsyncThrowingStream<OWStreamUpdate, Error>.Continuation) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0.6.x error path answers HTTP 200 with a literal `null` body.
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else {
            c.yield(.error(L("Falha ao iniciar o stream"))); return
        }
        if let full = try? JSONDecoder().decode(OWFullCompletion.self, from: data) {
            if let err = full.errorMessage { c.yield(.error(err)); return }
            let calls = (full.choices?.first?.message?.tool_calls ?? []).compactMap { d -> OWToolCall? in
                guard let name = d.function?.name, !name.isEmpty else { return nil }
                return OWToolCall(name: name, arguments: d.function?.arguments ?? "")
            }
            if let t = full.text, !t.isEmpty { c.yield(.textDelta(t)) }
            for call in calls { c.yield(.toolCall(call)) }
            if !(full.text ?? "").isEmpty || !calls.isEmpty {
                c.yield(.done)
                return
            }
        }
        if let err = extractError(trimmed) { c.yield(.error(err)) }
    }

    /// Internal so the sentence a refusal turns into can be pinned directly.
    static func extractError(_ body: String) -> String? {
        // FastAPI/Open WebUI errors are usually {"detail": "..."} or {"message": "..."}.
        if let data = body.data(using: .utf8), let s = OWErrorSentence.sentence(data) { return s }
        return body.count < 300 && !body.isEmpty ? body : nil
    }
}

/// `content` that may be a plain string or an array of typed parts.
struct OWFlexText: Decodable {
    var text: String
    init(from decoder: Decoder) throws {
        let sv = try decoder.singleValueContainer()
        if let s = try? sv.decode(String.self) { text = s; return }
        struct P: Decodable { var type: String?; var text: String? }
        if let parts = try? sv.decode([P].self) {
            text = parts.compactMap(\.text).joined(); return
        }
        text = ""
    }
}

/// `error` that may be a string, {message}, or {detail}.
struct OWErrorBody: Decodable {
    var message: String?
    enum CodingKeys: String, CodingKey { case message, detail }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            message = s; return
        }
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        message = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .message) }
            ?? c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .detail) }
    }
}

/// A single SSE chunk from /api/chat/completions (OpenAI shape).
struct OWCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
            var reasoning: String?
            var reasoning_content: String?
            var tool_calls: [OWToolCallDelta]?

            enum CodingKeys: String, CodingKey { case content, reasoning, reasoning_content, tool_calls }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = (try? c.decode(OWFlexText.self, forKey: .content))?.text
                reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
                reasoning_content = try? c.decodeIfPresent(String.self, forKey: .reasoning_content)
                tool_calls = try? c.decodeIfPresent([OWToolCallDelta].self, forKey: .tool_calls)
            }
        }
        var delta: Delta?
        var finish_reason: String?
    }

    var choices: [Choice]?
    var error: OWErrorBody?
    var detail: String?

    var errorMessage: String? { error?.message ?? detail }
}

/// One piece of a structured tool call, as streamed.
struct OWToolCallDelta: Decodable {
    struct Function: Decodable { var name: String?; var arguments: String? }
    var index: Int?
    var function: Function?
    enum CodingKeys: String, CodingKey { case index, function }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try? c.decodeIfPresent(Int.self, forKey: .index)
        function = try? c.decodeIfPresent(Function.self, forKey: .function)
    }
}

/// The prepended web-search frame: `data: {"sources": [ … ]}` (no choices key).
struct OWSourcesFrame: Decodable {
    var sources: [OWLossy<OWSourceEntry>]?
    var webSources: [OWWebSource] {
        OWSourceEntry.webSources((sources ?? []).compactMap(\.value))
    }
}

/// A complete (non-streamed) completion body.
struct OWFullCompletion: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable {
            var content: OWFlexText?
            var reasoning_content: String?
            var tool_calls: [OWToolCallDelta]?
        }
        var message: Msg?
        var text: String?
    }
    var choices: [Choice]?
    var error: OWErrorBody?
    var detail: String?

    var text: String? { choices?.first.flatMap { $0.message?.content?.text ?? $0.text } }
    var errorMessage: String? { error?.message ?? detail }
}
