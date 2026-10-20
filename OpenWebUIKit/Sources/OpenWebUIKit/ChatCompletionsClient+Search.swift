import Foundation

/// What `streamReply` may do about web search on this turn.
public struct OWReplySearch: Sendable {
    /// Declare `OWWebSearchTool`, so the model can ask for a search.
    public var offer: Bool
    /// Run a search when the model asks for one — even undeclared: Gemma writes
    /// out a `search_web` call on its own when it has no tool and no answer.
    /// False when the server has web search off, or the app already searched
    /// for this turn.
    public var mayRun: Bool

    public init(offer: Bool, mayRun: Bool) { self.offer = offer; self.mayRun = mayRun }

    public static let off = OWReplySearch(offer: false, mayRun: false)
}

extension ChatCompletionsClient {

    /// Models whose provider refused a request that carried `tools` (Ollama
    /// models without tool support answer 400 "does not support tools"). Not
    /// offered the tool again until the app restarts.
    nonisolated(unsafe) private static var refusesTools: Set<String> = []
    private static let refusesToolsLock = NSLock()

    static func toolsRefused(by model: String) -> Bool {
        refusesToolsLock.lock(); defer { refusesToolsLock.unlock() }
        return refusesTools.contains(model)
    }
    static func rememberToolsRefused(by model: String, _ refused: Bool = true) {
        refusesToolsLock.lock(); defer { refusesToolsLock.unlock() }
        if refused { refusesTools.insert(model) } else { refusesTools.remove(model) }
    }

    /// `stream`, plus everything a tool call needs on a request that does not
    /// come from a browser tab (where the server would run it):
    ///
    /// - text-form tool calls are cut out of what is shown, spoken and saved;
    /// - a call — structured or written out — runs one web search through the
    ///   server's own engine, and the model is asked again with the results
    ///   attached (the same `files` entry the chat's "Buscar na web" sends), no
    ///   tools offered, so a turn makes at most one search;
    /// - a provider that rejects `tools` is asked again without them.
    ///
    /// `.toolCall` never reaches the caller; `.searching`, `.sources` and
    /// `.searchFailed` do.
    public func streamReply(model: String,
                            messages: [OWChatMessageInput],
                            files: [OWAttachment] = [],
                            options: OWStreamOptions = .init(),
                            search: OWReplySearch) -> AsyncThrowingStream<OWStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runReply(model: model, messages: messages, files: files,
                                            options: options, search: search, into: continuation)
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

    private enum PassEnd: Equatable { case answered, called([OWToolCall]), refusedTools, failed }

    private func runReply(model: String, messages: [OWChatMessageInput], files: [OWAttachment],
                          options: OWStreamOptions, search: OWReplySearch,
                          into c: AsyncThrowingStream<OWStreamUpdate, Error>.Continuation) async throws {
        let offer = search.offer && search.mayRun && !Self.toolsRefused(by: model)
        var plain = options
        plain.offerWebSearch = false
        var first = options
        first.offerWebSearch = offer
        var (end, shown) = try await pass(model: model, messages: messages, files: files, options: first,
                                          toolsOffered: offer, lead: "", into: c)
        if end == .refusedTools {
            (end, shown) = try await pass(model: model, messages: messages, files: files, options: plain,
                                          toolsOffered: false, lead: "", into: c)
            // Remembered only once the same request without `tools` went through:
            // a server that is simply down fails both ways.
            if end != .failed { Self.rememberToolsRefused(by: model) }
        }
        guard case .called(let calls) = end else { return }
        try Task.checkCancellation()

        var followUp = messages
        var followFiles = files
        var searched = false
        if search.mayRun {
            let asked = calls.flatMap(\.searchQueries)
            let queries = asked.isEmpty ? Self.lastUserText(messages).map { [$0] } ?? [] : Array(asked.prefix(3))
            c.yield(.searching(queries))
            do {
                guard !queries.isEmpty else { throw OWError.decoding("web_search") }
                let found = try await client.searchWeb(queries: queries)
                followFiles.append(found.attachment)
                let sources = found.urls.map { OWWebSource(name: URL(string: $0)?.host ?? $0, url: $0) }
                if !sources.isEmpty { c.yield(.sources(sources)); searched = true }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                c.yield(.searchFailed(L("Busca na web indisponível no servidor. Verifique o mecanismo de busca no Open WebUI.")))
                followUp = Self.noting(Self.searchFailedNote, in: messages)
            }
        } else {
            followUp = Self.noting(Self.searchOffNote, in: messages)
        }
        try Task.checkCancellation()
        // No tools on this one, so it cannot ask again; a call it writes out
        // anyway is still cut, and the reply is whatever text is left.
        // The server answers an attached search with its own `sources` frame,
        // named after the query and without the pages' addresses; the list
        // already sent is the one with the sites.
        _ = try await pass(model: model, messages: followUp, files: followFiles, options: plain,
                           toolsOffered: false, lead: shown ? "\n\n" : "", keepSources: !searched, into: c)
    }

    /// One request. Text goes out through the filter; a call ends the pass.
    /// `lead` goes ahead of the first text it shows — the gap after whatever the
    /// model said before it asked for the search.
    private func pass(model: String, messages: [OWChatMessageInput], files: [OWAttachment],
                      options: OWStreamOptions, toolsOffered: Bool, lead: String,
                      keepSources: Bool = true, into c: AsyncThrowingStream<OWStreamUpdate, Error>.Continuation) async throws -> (PassEnd, Bool) {
        var filter = OWToolCallFilter()
        var structured: [OWToolCall] = []
        var shown = false
        var done = false
        var failed = false
        func show(_ text: String) {
            guard !text.isEmpty else { return }
            c.yield(.textDelta(shown ? text : lead + text))
            shown = true
        }
        do {
            for try await u in stream(model: model, messages: messages, files: files, options: options) {
                switch u {
                case .textDelta(let d):
                    show(filter.feed(d))
                case .toolCall(let call):
                    structured.append(call)
                case .error where toolsOffered && !shown:
                    return (.refusedTools, false)
                case .error:
                    failed = true
                    c.yield(u)
                case .done:
                    done = true
                case .sources where !keepSources:
                    break
                default:
                    c.yield(u)
                }
            }
        } catch let e as OWError where toolsOffered && !shown {
            if case .notAuthenticated = e { throw e }
            return (.refusedTools, false)
        } catch let e as OWError {
            // Reported by the caller as it always was; recorded here only so a
            // retry that failed too is not taken for a provider without tools.
            if !toolsOffered { failed = true }
            throw e
        }
        try Task.checkCancellation()
        show(filter.finish())
        let calls = structured + filter.calls
        if !calls.isEmpty { return (.called(calls), shown) }
        if done { c.yield(.done) }
        return (failed ? .failed : .answered, shown)
    }

    static func lastUserText(_ messages: [OWChatMessageInput]) -> String? {
        messages.last { $0.role == "user" }.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
    }

    /// Written for the model, not the user — hence English, like the tool spec:
    /// it reaches whatever language the conversation is in without being one.
    static let searchFailedNote = "(The web search you asked for failed. Answer from what you already know, in the language of this conversation, and say briefly that it may be out of date. Do not try to call a tool.)"
    static let searchOffNote = "(Web search is not available here. Answer from what you already know, in the language of this conversation, and say briefly that it may be out of date. Do not try to call a tool.)"

    /// The note goes on the end of the last user turn and not in a system
    /// message: several chat templates (Gemma's among them) reject a system
    /// turn anywhere but first.
    static func noting(_ note: String, in messages: [OWChatMessageInput]) -> [OWChatMessageInput] {
        var m = messages
        if let i = m.lastIndex(where: { $0.role == "user" }) {
            m[i].text += "\n\n" + note
        } else {
            m.append(OWChatMessageInput(role: "user", text: note))
        }
        return m
    }
}
