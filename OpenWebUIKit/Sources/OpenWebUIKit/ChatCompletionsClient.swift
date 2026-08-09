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
    public init(temperature: Double? = nil, webSearch: Bool = false, toolIDs: [String] = []) {
        self.temperature = temperature; self.webSearch = webSearch; self.toolIDs = toolIDs
    }
}

/// High-level events the UI reacts to as a reply streams in.
public enum OWStreamUpdate: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    /// Web-search citations (Open WebUI prepends a `data: {"sources": …}` frame
    /// before the first token when the RAG web-search path runs).
    case sources([OWWebSource])
    case error(String)
    case done
}

/// Streams a reply from POST /api/chat/completions. Open WebUI exposes an
/// OpenAI-compatible endpoint: newline-delimited `data: {json}` frames whose
/// `choices[0].delta.content` carries the tokens, terminated by `data: [DONE]`.
public final class ChatCompletionsClient: @unchecked Sendable {
    private let client: OpenWebUIClient
    public init(client: OpenWebUIClient) { self.client = client }

    public func stream(model: String,
                       messages: [OWChatMessageInput],
                       files: [OWAttachment] = [],
                       options: OWStreamOptions = .init()) -> AsyncThrowingStream<OWStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try buildRequest(model: model, messages: messages, files: files, options: options)
                    let (bytes, resp) = try await client.longSession.bytes(for: req)

                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 401 || http.statusCode == 403 {
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

                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        let line = rawLine.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

                        if payload == "[DONE]" {
                            continuation.yield(.done)
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
                                    continuation.yield(.reasoningDelta(r))
                                }
                                if let t = delta.content, !t.isEmpty {
                                    continuation.yield(.textDelta(t))
                                }
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
        req.httpBody = try JSONEncoder().encode(
            Body(model: model, messages: messages, stream: true,
                 temperature: options.temperature, files: files.isEmpty ? nil : files,
                 tool_ids: options.toolIDs.isEmpty ? nil : options.toolIDs,
                 features: options.webSearch ? Body.Features(web_search: true) : nil,
                 params: needsLegacy ? Body.Params(function_calling: "legacy") : nil)
        )
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
    private static func yieldJSONCompletion(_ body: String,
                                            into c: AsyncThrowingStream<OWStreamUpdate, Error>.Continuation) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0.6.x error path answers HTTP 200 with a literal `null` body.
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else {
            c.yield(.error(L("Falha ao iniciar o stream"))); return
        }
        if let full = try? JSONDecoder().decode(OWFullCompletion.self, from: data) {
            if let err = full.errorMessage { c.yield(.error(err)); return }
            if let t = full.text, !t.isEmpty {
                c.yield(.textDelta(t))
                c.yield(.done)
                return
            }
        }
        if let err = extractError(trimmed) { c.yield(.error(err)) }
    }

    private static func extractError(_ body: String) -> String? {
        // FastAPI/Open WebUI errors are usually {"detail": "..."} or {"message": "..."}.
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? String { return d }
            if let m = obj["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
        }
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

            enum CodingKeys: String, CodingKey { case content, reasoning, reasoning_content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = (try? c.decode(OWFlexText.self, forKey: .content))?.text
                reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
                reasoning_content = try? c.decodeIfPresent(String.self, forKey: .reasoning_content)
            }
        }
        var delta: Delta?
    }

    var choices: [Choice]?
    var error: OWErrorBody?
    var detail: String?

    var errorMessage: String? { error?.message ?? detail }
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
