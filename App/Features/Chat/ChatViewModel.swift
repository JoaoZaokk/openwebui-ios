import SwiftUI
import OpenWebUIKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [OWMessage] = []
    @Published var input: String = ""
    @Published var isStreaming = false
    @Published var isLoadingHistory = false
    @Published var error: String?
    @Published var selectedModel: String?
    @Published var title: String

    /// Images staged for the next message, as data: URLs (vision).
    @Published var pendingImageURLs: [String] = []
    /// Documents staged for the next message (uploaded → RAG).
    @Published var pendingDocuments: [OWAttachment] = []
    @Published var uploading = false
    /// Composer toggle: web search for the next reply.
    @Published var webSearch = false
    /// True from send() until the first stream signal, when web search is on —
    /// the server searches before the first token and emits no progress events
    /// over plain SSE, so we show a local "Pesquisando na web…" status.
    @Published var awaitingWebSearch = false

    let models: [OWModel]

    /// A temporary chat is never saved to the server (ephemeral).
    let temporary: Bool

    /// nil until the conversation is persisted server-side (new chat).
    private(set) var chatID: String?
    /// Fired after a turn finishes so the list can refresh.
    var onChanged: (() -> Void)?

    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private let cache: ServerChatCache?
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyLoaded = false
    /// Guards send() while a save is in flight (prevents duplicate createChat).
    private var isPersisting = false
    /// True when the currently-shown history came from the offline cache.
    @Published private(set) var offline = false

    init(client: OpenWebUIClient, completions: ChatCompletionsClient,
         chat: OWChatSummary?, models: [OWModel], defaultModel: String?,
         temporary: Bool = false, cache: ServerChatCache? = nil) {
        self.client = client
        self.completions = completions
        self.cache = cache
        self.models = models
        self.temporary = temporary
        self.chatID = chat?.id
        self.title = chat?.title ?? (temporary ? L("Conversa temporária") : L("Nova conversa"))
        self.selectedModel = defaultModel
    }

    var isNewChat: Bool { chatID == nil }

    var selectedModelName: String {
        guard let id = selectedModel else { return L("Selecionar modelo") }
        return models.first { $0.id == id }?.shortName ?? id
    }

    func selectModel(_ id: String) { selectedModel = id }

    // MARK: - History

    /// Loads history once, in a Task owned by the view model (not a SwiftUI
    /// `.task`, which gets cancelled mid-navigation and blanks the messages).
    func loadHistoryIfNeeded() {
        guard chatID != nil, !historyLoaded, historyTask == nil else { return }
        runHistoryLoad()
    }

    func reloadHistory() async {
        historyTask?.cancel(); historyLoaded = false
        runHistoryLoad()
        await historyTask?.value
    }

    private func runHistoryLoad() {
        guard let id = chatID else { return }
        isLoadingHistory = true
        historyTask = Task { @MainActor in
            defer { self.isLoadingHistory = false; self.historyTask = nil }
            do {
                let chat = try await self.client.chat(id)
                self.adopt(chat)
                if let m = chat.models.first { self.selectedModel = m }
                self.cache?.cacheChat(chat)   // keep the offline copy fresh
                self.offline = false
                self.historyLoaded = true
            } catch is CancellationError {
            } catch {
                // Offline / server error: fall back to the cached copy if we have one.
                if let cached = self.cache?.cachedChat(id: id) {
                    self.messages = cached.messages
                    if let m = cached.models.first { self.selectedModel = m }
                    if !cached.title.isEmpty { self.title = cached.title }
                    self.offline = true
                    self.historyLoaded = true
                } else {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Server wins for every message it knows; local-only (unsaved) messages are
    /// kept at the end instead of being clobbered by a refresh.
    private func adopt(_ chat: OWChat) {
        let known = Set(chat.messages.map(\.id))
        let localOnly = messages.filter { !known.contains($0.id) }
        let merged = chat.messages + localOnly
        if merged != messages { messages = merged }
        if !chat.title.isEmpty, chat.title != title { title = chat.title }
    }

    /// Silent periodic refresh while the chat is on screen, so replies generated
    /// on the web UI show up without leaving the conversation.
    func refreshRemote() async {
        guard let id = chatID, !isStreaming, !isPersisting, historyTask == nil else { return }
        guard let chat = try? await client.chat(id) else { return }
        guard !isStreaming, !isPersisting else { return }   // state may have changed mid-await
        adopt(chat)
    }

    // MARK: - Sending

    /// Stage images (raw data) for the next message — downscaled to data: URLs.
    func addImageData(_ datas: [Data]) {
        for d in datas {
            if let url = AttachImage.dataURL(from: d) { pendingImageURLs.append(url) }
        }
    }

    func removePendingImage(_ url: String) { pendingImageURLs.removeAll { $0 == url } }
    func removePendingDocument(_ att: OWAttachment) { pendingDocuments.removeAll { $0.id == att.id } }

    /// Upload raw data and stage it as a document attachment.
    private func uploadAndAttach(_ data: Data, filename: String, mime: String, displayName: String? = nil) async {
        uploading = true; defer { uploading = false }
        do {
            let f = try await client.uploadFile(data: data, filename: filename, mime: mime)
            pendingDocuments.append(OWAttachment(type: "file", id: f.id, name: displayName ?? f.filename))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addDocument(data: Data, filename: String, mime: String) async {
        await uploadAndAttach(data, filename: filename, mime: mime)
    }

    /// Attach a note's markdown as a document (RAG).
    func attachNote(_ note: OWNote) async {
        let md = "# \(note.title)\n\n\(note.markdown)"
        await uploadAndAttach(Data(md.utf8), filename: "nota.md", mime: "text/markdown", displayName: note.title)
    }

    /// Attach another chat's transcript as a document (RAG).
    func attachChatReference(_ summary: OWChatSummary) async {
        uploading = true; defer { uploading = false }
        do {
            let chat = try await client.chat(summary.id)
            let transcript = chat.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
            let f = try await client.uploadFile(data: Data(transcript.utf8),
                                                filename: "conversa.txt", mime: "text/plain")
            pendingDocuments.append(OWAttachment(type: "file", id: f.id, name: summary.title))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Process a web page server-side and attach its content (RAG).
    func attachWebPage(_ urlString: String) async {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        uploading = true; defer { uploading = false }
        do {
            let (name, content) = try await client.processWebPage(url: url)
            guard !content.isEmpty else { self.error = L("Não foi possível ler a página."); return }
            await uploadAndAttach(Data(content.utf8), filename: "pagina.txt", mime: "text/plain", displayName: name)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Attach a knowledge base (collection) by reference — RAG over its documents.
    func attachKnowledge(_ kb: OWNamedItem) {
        pendingDocuments.append(OWAttachment(type: "collection", id: kb.id, name: kb.name))
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImageURLs
        let docs = pendingDocuments
        guard (!text.isEmpty || !images.isEmpty || !docs.isEmpty),
              !isStreaming, !isPersisting, let model = selectedModel else { return }
        input = ""; pendingImageURLs = []; pendingDocuments = []; error = nil

        messages.append(OWMessage(role: .user, content: text,
                                  timestamp: Date().timeIntervalSince1970,
                                  imageURLs: images, documents: docs))
        let assistant = OWMessage(role: .assistant, content: "", model: model)
        messages.append(assistant)
        isStreaming = true
        awaitingWebSearch = webSearch
        beginBackgroundHold()   // let the reply finish if the user backgrounds the app

        // Context = everything except the empty assistant placeholder we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        streamTask = Task { await self.runStream(model: model, convo: convo, files: docs,
                                                 assistantID: assistant.id, query: text) }
    }

    private func runStream(model: String, convo: [OWChatMessageInput],
                           files: [OWAttachment], assistantID: String, query: String) async {
        var sawText = false
        var streamFiles = files
        // Web search: run it OURSELVES via /api/v1/retrieval/process/web/search
        // (same engine the web UI uses) and attach the result — works on every
        // server version. features.web_search stays only as fallback: some
        // servers never run the legacy RAG gate in /api/chat/completions.
        var legacyFallback = false
        if webSearch {
            do {
                let res = try await client.searchWeb(queries: [query])
                streamFiles.append(res.attachment)
                if let i = index(of: assistantID) {
                    messages[i].sources = res.urls.map {
                        OWWebSource(name: URL(string: $0)?.host ?? $0, url: $0)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // The server's own search failed (engine misconfigured, blocked
                // or rate-limited). Open WebUI reports this only over socket.io,
                // so without saying it here the model just answers "I have no
                // internet access" and the user blames the app.
                self.error = L("Busca na web indisponível no servidor. Verifique o mecanismo de busca no Open WebUI.")
                awaitingWebSearch = false
                legacyFallback = true
            }
        }
        do {
            for try await update in completions.stream(model: model, messages: convo, files: streamFiles,
                                                       options: OWStreamOptions(webSearch: legacyFallback)) {
                awaitingWebSearch = false
                switch update {
                case .textDelta(let d):
                    sawText = true
                    append(assistantID, d)
                case .reasoningDelta(let d):
                    appendReasoning(assistantID, d)
                case .sources(let list):
                    if let i = index(of: assistantID) { messages[i].sources = list }
                case .error(let msg):
                    setContent(assistantID, friendlyError(msg))
                case .done:
                    break
                }
            }
            // A reply that is only reasoning still said something — the
            // disclosure shows it, so don't stamp it "(no response)" (which
            // would then be persisted over a real turn).
            if !sawText, let i = index(of: assistantID),
               messages[i].content.isEmpty, messages[i].reasoning.isEmpty {
                messages[i].content = L("_(sem resposta)_")
            }
        } catch is CancellationError {
            // user stopped — keep whatever streamed so far
        } catch {
            let msg = friendlyError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if let i = index(of: assistantID), messages[i].content.isEmpty {
                messages[i].content = "⚠️ \(msg)"
            } else {
                self.error = msg
            }
        }
        awaitingWebSearch = false
        isStreaming = false
        notifyReplyIfBackgrounded(assistantID)
        endBackgroundHold()
        // Ask for notification permission only once the first reply has landed —
        // asking at send time throws the system alert over a streaming answer.
        askForNotificationsOnce()
        await persist()
    }

    /// Map raw server errors to clearer pt-BR messages.
    private func friendlyError(_ msg: String) -> String {
        let l = msg.lowercased()
        if l.contains("image input") || l.contains("support image") || l.contains("no endpoints found that support image") {
            return L("Este modelo não tem visão (não aceita imagens). Escolha um modelo com visão para enviar imagens.")
        }
        return msg
    }

    /// Saves the conversation to the server (creates on the first turn, appends after).
    private func persist() async {
        guard !temporary else { return }   // ephemeral — never saved
        guard !messages.isEmpty, let model = selectedModel else { return }
        isPersisting = true; defer { isPersisting = false }
        let title = chatTitle()
        do {
            if let id = chatID {
                // Merge-safe append: the server's copy — including web-generated
                // `output` content, sources and the branching graph — is kept
                // verbatim; only messages the server has never seen are added.
                // On failure NOTHING is written (no destructive fallback).
                try await client.syncChat(id: id, localMessages: messages, model: model)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: messages)
                chatID = id
                self.title = title
                onChanged?()
                await autoTitle(id: id, model: model)   // replace the first-message stub
                return
            }
            onChanged?()
        } catch {
            // Chat stays on screen, but tell the user the turn didn't reach the
            // server instead of losing it silently.
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func chatTitle() -> String {
        if chatID != nil { return title }   // keep an existing chat's title
        if let first = messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            return String(first.prefix(50))
        }
        return title
    }

    /// After the first exchange, ask the model for a concise title (the server
    /// otherwise keeps the truncated first message). Best-effort: any failure
    /// leaves the stub title in place. Runs once, right after the chat is created.
    private func autoTitle(id: String, model: String) async {
        guard let user = messages.first(where: { $0.role == .user })?.content, !user.isEmpty,
              let reply = messages.first(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
        else { return }
        guard let generated = await generateTitle(model: model, user: user, reply: reply) else { return }
        self.title = generated
        try? await client.updateChat(id: id, title: generated, model: model, messages: messages)
        onChanged?()
    }

    /// One-shot, non-persisted completion that returns a short chat title in the
    /// conversation's own language. Reuses the streaming endpoint and concatenates.
    private func generateTitle(model: String, user: String, reply: String) async -> String? {
        let prompt = """
        Generate a concise 3-6 word title for the following conversation. \
        Use the same language as the conversation. Reply with ONLY the title — \
        no quotes, no punctuation at the end, no preamble.

        User: \(user.prefix(600))
        Assistant: \(reply.prefix(600))
        """
        var out = ""
        do {
            for try await update in completions.stream(
                model: model,
                messages: [OWChatMessageInput(role: "user", text: prompt)],
                files: [], options: OWStreamOptions()) {
                switch update {
                case .textDelta(let d): out += d
                case .done: break
                case .error: return nil
                case .reasoningDelta: break
                }
            }
        } catch { return nil }
        return Self.cleanTitle(out)
    }

    /// Trims a model's title reply down to a single clean line.
    static func cleanTitle(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading <think>…</think> block a reasoning model may prepend.
        if let close = s.range(of: "</think>") { s = String(s[close.upperBound...]) }
        s = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`.。"))
        return s.isEmpty ? nil : String(s.prefix(60))
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
        awaitingWebSearch = false
    }

    // MARK: - Mutation helpers

    private func index(of id: String) -> Int? { messages.firstIndex { $0.id == id } }
    private func append(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content += text }
    }
    private func appendReasoning(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].reasoning += text }
    }
    private func setContent(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content = text }
    }

    // MARK: - Background completion + local notification

    /// Post a local notification if the reply finished while the app was
    /// backgrounded — so a mid-stream reply the user walked away from pings them
    /// when it's ready. No-op on macOS (no application-state concept here).
    private func notifyReplyIfBackgrounded(_ id: String) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return }
        guard let i = index(of: id) else { return }
        let body = messages[i].content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let snippet = body.count > 140 ? String(body.prefix(140)) + "…" : body
        let heading = title.isEmpty ? L("Resposta pronta") : title
        LocalNotifier.replyFinished(title: heading, body: snippet, threadID: chatID)
        #endif
    }

    #if canImport(UIKit)
    private static var askedForNotifications = false
    private func askForNotificationsOnce() {
        guard !Self.askedForNotifications else { return }
        Self.askedForNotifications = true
        LocalNotifier.requestAuthorization()
    }
    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid
    private func beginBackgroundHold() {
        endBackgroundHold()
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: "chat-reply") { [weak self] in
            self?.endBackgroundHold()
        }
    }
    private func endBackgroundHold() {
        guard backgroundHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundHold)
        backgroundHold = .invalid
    }
    #else
    private func beginBackgroundHold() {}
    private func endBackgroundHold() {}
    private func askForNotificationsOnce() {}
    #endif
}

/// Local (on-device) notifications — pings when a chat reply finishes while the
/// app is backgrounded. No push server or APNs: `UNUserNotificationCenter` posts
/// these itself. Colocated here to avoid a new project file.
enum LocalNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Fire a notification for a finished reply. `threadID` (the chat id) collapses
    /// repeat pings for the same chat into one thread.
    static func replyFinished(title: String, body: String, threadID: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let threadID { content.threadIdentifier = threadID }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
