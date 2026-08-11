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

    /// Workspace tools (`/api/v1/tools/`) the server may call for the next
    /// reply. Empty = none, which is what every version before this shipped.
    @Published var selectedToolIDs: Set<String> = []
    /// Tools this account can reach — loaded lazily the first time the picker
    /// opens, so a chat that never uses tools costs no request.
    @Published private(set) var availableTools: [OWNamedItem] = []
    @Published private(set) var loadingTools = false

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

    // MARK: - Branching history
    // The full node tree (id → node) is the source of truth for structure; the
    // rendered `messages` array is only the active branch (currentLeafId → root).
    // Edit / regenerate / retry add SIBLING nodes and move the leaf — nothing is
    // ever deleted, so branches (including ones made in the web UI) survive.
    private var tree: [String: OWMessage] = [:]
    private var currentLeafId: String?

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
        return ModelAliases.shared.display(id: id, fallback: models.first { $0.id == id }?.shortName)
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
                    self.adopt(cached)
                    if let m = cached.models.first { self.selectedModel = m }
                    self.offline = true
                    self.historyLoaded = true
                } else {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Server wins for every node it knows; local-only (unsaved) nodes are kept
    /// instead of being clobbered by a refresh.
    ///
    /// The leaf is only taken from the server when it points at a node we've never
    /// seen — that means the web UI produced something new. Otherwise the branch
    /// the user is currently looking at wins, so a background refresh can't yank
    /// them off the branch they just switched to.
    private func adopt(_ chat: OWChat) {
        let serverNodes = chat.allMessages.isEmpty ? chat.messages : chat.allMessages
        let serverLeafIsNew = chat.currentId.map { tree[$0] == nil } ?? false
        // A turn we haven't managed to save yet must not be scrolled off screen by
        // a refresh, so it pins the leaf until the next successful write.
        let known = Set(serverNodes.map(\.id))
        let hasUnsaved = tree.keys.contains { !known.contains($0) }

        for n in serverNodes { tree[n.id] = n }
        if currentLeafId == nil || tree[currentLeafId!] == nil || (serverLeafIsNew && !hasUnsaved) {
            currentLeafId = chat.currentId ?? serverNodes.last?.id ?? chat.messages.last?.id
        }
        rebuildActiveBranch()
        // Broken/absent graph: fall back to whatever flat list the server gave us,
        // still keeping anything local it doesn't know about.
        if messages.isEmpty, !chat.messages.isEmpty {
            let known = Set(chat.messages.map(\.id))
            messages = chat.messages + tree.values.filter { !known.contains($0.id) }
        }
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

    /// Fetches the workspace tool list once (idempotent — safe to call on every
    /// picker open).
    func loadTools() {
        guard availableTools.isEmpty, !loadingTools else { return }
        loadingTools = true
        Task {
            defer { loadingTools = false }
            guard let list = try? await client.tools() else { return }
            availableTools = list
            // Drop selections for tools this account lost access to, so we never
            // send a tool_id the server will reject.
            let ids = Set(list.map(\.id))
            selectedToolIDs.formIntersection(ids)
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImageURLs
        let docs = pendingDocuments
        guard (!text.isEmpty || !images.isEmpty || !docs.isEmpty),
              !isStreaming, !isPersisting, let model = selectedModel else { return }
        input = ""; pendingImageURLs = []; pendingDocuments = []; error = nil

        let now = Date().timeIntervalSince1970
        var user = OWMessage(role: .user, content: text, timestamp: now,
                             imageURLs: images, documents: docs)
        user.parentId = currentLeafId
        var assistant = OWMessage(role: .assistant, content: "", model: model, timestamp: now + 0.001)
        assistant.parentId = user.id
        tree[user.id] = user
        tree[assistant.id] = assistant
        currentLeafId = assistant.id
        rebuildActiveBranch()

        startAssistantTurn(model: model, assistantID: assistant.id, files: docs, query: text)
    }

    /// Streams into the (already-created, empty) assistant node at the leaf. Shared
    /// by send / regenerate / retry / edit so all four get the same context rules,
    /// web-search handling and background hold.
    private func startAssistantTurn(model: String, assistantID: String,
                                    files: [OWAttachment], query: String) {
        isStreaming = true
        awaitingWebSearch = webSearch
        beginBackgroundHold()   // let the reply finish if the user backgrounds the app

        // Context = the active branch except the empty assistant we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        streamTask = Task { await self.runStream(model: model, convo: convo, files: files,
                                                 assistantID: assistantID, query: query) }
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
            let options = OWStreamOptions(webSearch: legacyFallback,
                                          toolIDs: Array(selectedToolIDs))
            for try await update in completions.stream(model: model, messages: convo, files: streamFiles,
                                                       options: options) {
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
        syncBranchIntoTree()
        do {
            if let id = chatID {
                // Merge-safe tree write: the server's copy — including web-generated
                // `output` content, sources and every sibling branch — is kept
                // verbatim; only nodes the server has never seen are added, and the
                // leaf moves to the branch on screen. On failure NOTHING is written
                // (no destructive fallback).
                try await client.syncChatTree(id: id, title: title, models: [model],
                                              tree: Array(tree.values), currentId: currentLeafId)
            } else {
                let id = try await client.createChatTree(title: title, models: [model],
                                                         tree: Array(tree.values), currentId: currentLeafId)
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
        // renameChat patches the title on the raw server JSON. updateChat would
        // rewrite the whole chat through our lossy model and drop whatever the
        // server keeps that we don't model (`output` text, sources, branches).
        try? await client.renameChat(id, to: generated)
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
                case .reasoningDelta, .sources: break
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

    // MARK: - Branching (edit / regenerate / retry / switch)

    /// Regenerate an assistant reply, optionally with a different model. Adds a
    /// fresh sibling under the same parent and moves the leaf — the old reply stays
    /// reachable through the branch switcher.
    func regenerate(messageID: String, model: String? = nil) {
        guard !isStreaming, !isPersisting, let node = tree[messageID], node.role == .assistant else { return }
        guard let mdl = model ?? node.model ?? selectedModel else { return }
        error = nil
        var reply = OWMessage(role: .assistant, content: "", model: mdl,
                              timestamp: Date().timeIntervalSince1970)
        reply.parentId = node.parentId
        tree[reply.id] = reply
        currentLeafId = reply.id
        if model != nil { selectedModel = mdl }   // reflect the retry model in the picker
        rebuildActiveBranch()
        startAssistantTurn(model: mdl, assistantID: reply.id,
                           files: [], query: question(above: reply.id))
    }

    /// Edit a user message: forks a new user node with the new text plus a fresh
    /// reply, as a sibling branch — the original question and its answer are kept.
    func editUser(messageID: String, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !isPersisting, !text.isEmpty,
              let node = tree[messageID], node.role == .user,
              let model = selectedModel else { return }
        error = nil
        let now = Date().timeIntervalSince1970
        var user = OWMessage(role: .user, content: text, timestamp: now,
                             imageURLs: node.imageURLs, documents: node.documents)
        user.parentId = node.parentId
        var reply = OWMessage(role: .assistant, content: "", model: model, timestamp: now + 0.001)
        reply.parentId = user.id
        tree[user.id] = user
        tree[reply.id] = reply
        currentLeafId = reply.id
        rebuildActiveBranch()
        startAssistantTurn(model: model, assistantID: reply.id,
                           files: node.documents, query: text)
    }

    /// Switch the visible branch at a forked message (the `‹ n/m ›` control).
    func switchBranch(messageID: String, delta: Int) {
        guard !isStreaming, !isPersisting, tree[messageID] != nil else { return }
        let sibs = siblings(of: messageID)
        guard sibs.count > 1, let idx = sibs.firstIndex(where: { $0.id == messageID }) else { return }
        let target = idx + delta
        guard sibs.indices.contains(target) else { return }
        currentLeafId = leaf(from: sibs[target].id)
        rebuildActiveBranch()
        Task { await self.persist() }   // remember the active branch server-side
    }

    /// For the UI: this message's position among its siblings (1-based) and the
    /// sibling count, or nil when it isn't a fork point.
    func branchInfo(for messageID: String) -> (index: Int, total: Int)? {
        let sibs = siblings(of: messageID)
        guard sibs.count > 1, let idx = sibs.firstIndex(where: { $0.id == messageID }) else { return nil }
        return (idx + 1, sibs.count)
    }

    // MARK: - Tree internals

    /// Rebuild the rendered active branch by walking currentLeafId → root.
    private func rebuildActiveBranch() {
        guard let leaf = currentLeafId, tree[leaf] != nil else { return }
        var chain: [OWMessage] = []
        var id: String? = leaf
        var guardCount = 0
        while let i = id, let m = tree[i], guardCount < 10_000 {
            chain.append(m); id = m.parentId; guardCount += 1
        }
        let branch = Array(chain.reversed())
        if branch != messages { messages = branch }
    }

    /// Fold the streamed active branch back into the tree before a write — the
    /// rendered array is what the stream mutates, the tree is what gets saved.
    private func syncBranchIntoTree() {
        for m in messages { tree[m.id] = m }
    }

    private func children(of id: String?) -> [OWMessage] {
        tree.values
            .filter { $0.parentId == id }
            .sorted { ($0.timestamp ?? 0, $0.id) < ($1.timestamp ?? 0, $1.id) }
    }

    private func siblings(of id: String) -> [OWMessage] {
        guard let node = tree[id] else { return [] }
        return children(of: node.parentId)
    }

    /// Walk down from a node to a leaf, always taking the newest child.
    private func leaf(from id: String) -> String {
        var cur = id, guardCount = 0
        while guardCount < 10_000, let next = children(of: cur).last { cur = next.id; guardCount += 1 }
        return cur
    }

    /// The user question this reply answers — the query web search should run.
    private func question(above replyID: String) -> String {
        var id = tree[replyID]?.parentId
        var guardCount = 0
        while let i = id, let m = tree[i], guardCount < 10_000 {
            if m.role == .user { return m.content }
            id = m.parentId; guardCount += 1
        }
        return ""
    }
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
