import SwiftUI
import OpenWebUIKit

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

    let models: [OWModel]

    /// A temporary chat is never saved to the server (ephemeral).
    let temporary: Bool

    /// nil until the conversation is persisted server-side (new chat).
    private(set) var chatID: String?
    /// Fired after a turn finishes so the list can refresh.
    var onChanged: (() -> Void)?

    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyLoaded = false

    // MARK: - Branching history
    // The full message tree (id → node) is the source of truth for structure; the
    // rendered `messages` array is the active branch (currentLeafId → root). Edit/
    // regenerate/retry add sibling nodes and move the leaf — nothing is deleted, so
    // branches (incl. web-UI ones) survive. `syncBranchIntoTree()` folds the
    // streamed active-branch content back before persisting.
    private var tree: [String: OWMessage] = [:]
    private var currentLeafId: String?

    init(client: OpenWebUIClient, completions: ChatCompletionsClient,
         chat: OWChatSummary?, models: [OWModel], defaultModel: String?, temporary: Bool = false) {
        self.client = client
        self.completions = completions
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
                self.loadTree(from: chat)
                if let m = chat.models.first { self.selectedModel = m }
                if !chat.title.isEmpty { self.title = chat.title }
                self.historyLoaded = true
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
        guard (!text.isEmpty || !images.isEmpty || !docs.isEmpty), !isStreaming, let model = selectedModel else { return }
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
        startAssistantTurn(model: model, assistantID: assistant.id, files: docs)
    }

    /// Builds the context from the active branch, then streams into the
    /// (already-created, empty) assistant node at the leaf. Shared by
    /// send / regenerate / retry / edit.
    private func startAssistantTurn(model: String, assistantID: String, files: [OWAttachment] = []) {
        isStreaming = true
        // Context = the active branch except the empty assistant we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        streamTask = Task { await self.runStream(model: model, convo: convo, files: files, assistantID: assistantID) }
    }

    private func runStream(model: String, convo: [OWChatMessageInput],
                           files: [OWAttachment], assistantID: String) async {
        var sawText = false
        do {
            for try await update in completions.stream(model: model, messages: convo, files: files,
                                                       options: OWStreamOptions(webSearch: webSearch)) {
                switch update {
                case .textDelta(let d):
                    sawText = true
                    append(assistantID, d)
                case .reasoningDelta:
                    break   // TODO: surface reasoning in a disclosure (phase 2)
                case .error(let msg):
                    setContent(assistantID, friendlyError(msg))
                case .done:
                    break
                }
            }
            if !sawText, let i = index(of: assistantID), messages[i].content.isEmpty {
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
        isStreaming = false
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

    /// Saves the conversation to the server (creates on the first turn, updates after).
    private func persist() async {
        guard !temporary else { return }   // ephemeral — never saved
        guard !messages.isEmpty, selectedModel != nil else { return }
        do {
            try await persistTree()
            onChanged?()
        } catch {
            // Non-fatal: the conversation stays on screen even if the save fails.
        }
    }

    /// Tree-preserving server write. Folds the streamed active-branch content back
    /// into the tree, adopts any nodes the web UI added since we loaded (so we don't
    /// clobber them), then writes the whole tree with the current leaf.
    private func persistTree() async throws {
        syncBranchIntoTree()
        let title = chatTitle()
        let models = [selectedModel].compactMap { $0 }
        if let id = chatID {
            if let server = try? await client.chat(id) {
                for n in server.allMessages where tree[n.id] == nil { tree[n.id] = n }
            }
            try await client.updateChatTree(id: id, title: title, models: models,
                                            tree: Array(tree.values), currentId: currentLeafId)
        } else {
            let id = try await client.createChatTree(title: title, models: models,
                                                     tree: Array(tree.values), currentId: currentLeafId)
            chatID = id
            self.title = title
        }
    }

    private func chatTitle() -> String {
        if chatID != nil { return title }   // keep an existing chat's title
        if let first = messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            return String(first.prefix(50))
        }
        return title
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
    }

    // MARK: - Mutation helpers

    private func index(of id: String) -> Int? { messages.firstIndex { $0.id == id } }
    private func append(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content += text }
    }
    private func setContent(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content = text }
    }

    // MARK: - Branching (edit / regenerate / retry / switch)

    /// Regenerate an assistant reply — optionally with a different model. Adds a
    /// fresh sibling under the same parent and moves the leaf; the old reply stays
    /// reachable via the branch switcher.
    func regenerate(messageID: String, model: String? = nil) {
        guard !isStreaming, let node = tree[messageID], node.role == .assistant else { return }
        guard let mdl = model ?? node.model ?? selectedModel else { return }
        var reply = OWMessage(role: .assistant, content: "", model: mdl,
                              timestamp: Date().timeIntervalSince1970)
        reply.parentId = node.parentId
        tree[reply.id] = reply
        currentLeafId = reply.id
        if model != nil { selectedModel = mdl }   // reflect the retry model in the picker
        rebuildActiveBranch()
        startAssistantTurn(model: mdl, assistantID: reply.id)
    }

    /// Edit a user message: forks a new user node (new content) + a fresh reply as a
    /// sibling branch, so the original question and its answer are preserved.
    func editUser(messageID: String, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !text.isEmpty,
              let node = tree[messageID], node.role == .user,
              let model = selectedModel else { return }
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
        startAssistantTurn(model: model, assistantID: reply.id)
    }

    /// Switch the visible branch at a forked message (the `‹ n/m ›` control).
    func switchBranch(messageID: String, delta: Int) {
        guard !isStreaming, tree[messageID] != nil else { return }
        let sibs = siblings(of: messageID)
        guard sibs.count > 1, let idx = sibs.firstIndex(where: { $0.id == messageID }) else { return }
        let newIndex = idx + delta
        guard sibs.indices.contains(newIndex) else { return }
        currentLeafId = leaf(from: sibs[newIndex].id)
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

    private func loadTree(from chat: OWChat) {
        let nodes = chat.allMessages.isEmpty ? chat.messages : chat.allMessages
        tree = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        currentLeafId = chat.currentId ?? chat.messages.last?.id ?? nodes.last?.id
        rebuildActiveBranch()
        if messages.isEmpty { messages = chat.messages }   // safety net
    }

    /// Rebuild the rendered active branch by walking currentLeafId → root.
    private func rebuildActiveBranch() {
        guard let leaf = currentLeafId, tree[leaf] != nil else { return }
        var chain: [OWMessage] = []
        var id: String? = leaf
        var guardN = 0
        while let i = id, let m = tree[i], guardN < 10_000 { chain.append(m); id = m.parentId; guardN += 1 }
        messages = chain.reversed()
    }

    /// Fold the active branch's (streamed) content back into the tree before a write.
    private func syncBranchIntoTree() {
        for m in messages { tree[m.id] = m }
    }

    private func children(of id: String?) -> [OWMessage] {
        tree.values.filter { $0.parentId == id }.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }
    private func siblings(of id: String) -> [OWMessage] {
        guard let node = tree[id] else { return [] }
        return children(of: node.parentId)
    }
    /// Walk down from a node to a leaf, always taking the newest child.
    private func leaf(from id: String) -> String {
        var cur = id, guardN = 0
        while guardN < 10_000, let next = children(of: cur).last { cur = next.id; guardN += 1 }
        return cur
    }
}
