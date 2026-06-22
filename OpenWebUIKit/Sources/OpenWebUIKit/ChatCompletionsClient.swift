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
    public init(temperature: Double? = nil, webSearch: Bool = false) {
        self.temperature = temperature; self.webSearch = webSearch
    }
}

/// High-level events the UI reacts to as a reply streams in.
public enum OWStreamUpdate: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
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
                    let (bytes, resp) = try await client.session.bytes(for: req)

                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            throw OWError.notAuthenticated
                        }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 800 { break } }
                        throw OWError.http(http.statusCode, Self.extractError(body) ?? "Falha ao iniciar o stream")
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

    private func buildRequest(model: String,
                             messages: [OWChatMessageInput],
                             files: [OWAttachment],
                             options: OWStreamOptions) throws -> URLRequest {
        var req = URLRequest(url: client.config.url("/api/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let t = client.token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(
            Body(model: model, messages: messages, stream: true,
                 temperature: options.temperature, files: files.isEmpty ? nil : files,
                 features: options.webSearch ? Body.Features(web_search: true) : nil)
        )
        return req
    }

    private struct Body: Encodable {
        var model: String
        var messages: [OWChatMessageInput]
        var stream: Bool
        var temperature: Double?
        var files: [OWAttachment]?
        var features: Features?
        struct Features: Encodable { var web_search: Bool }
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

/// A single SSE chunk from /api/chat/completions (OpenAI shape).
struct OWCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
            var reasoning: String?
            var reasoning_content: String?
        }
        var delta: Delta?
    }
    struct ErrorBody: Decodable { var message: String? }

    var choices: [Choice]?
    var error: ErrorBody?
    var detail: String?

    var errorMessage: String? { error?.message ?? detail }
}
