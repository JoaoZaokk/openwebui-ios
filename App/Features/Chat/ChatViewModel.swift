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
    private let cache: ServerChatCache?
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyLoaded = false
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
                self.messages = chat.messages
                if let m = chat.models.first { self.selectedModel = m }
                if !chat.title.isEmpty { self.title = chat.title }
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

        messages.append(OWMessage(role: .user, content: text,
                                  timestamp: Date().timeIntervalSince1970,
                                  imageURLs: images, documents: docs))
        let assistant = OWMessage(role: .assistant, content: "", model: model)
        messages.append(assistant)
        isStreaming = true

        // Context = everything except the empty assistant placeholder we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        streamTask = Task { await self.runStream(model: model, convo: convo, files: docs, assistantID: assistant.id) }
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
        guard !messages.isEmpty, let model = selectedModel else { return }
        let title = chatTitle()
        do {
            if let id = chatID {
                // updateChat REPLACES the whole chat server-side. If the web UI
                // added messages meanwhile (e.g. image generations), writing our
                // stale local array would erase them — so merge first: adopt the
                // fuller server history and re-append what only exists locally.
                if let server = try? await client.chat(id), server.messages.count > 0 {
                    let known = Set(server.messages.map(\.id))
                    let localOnly = messages.filter { !known.contains($0.id) }
                    if server.messages.count > messages.count - localOnly.count {
                        messages = server.messages + localOnly
                    }
                }
                try await client.updateChat(id: id, title: title, model: model, messages: messages)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: messages)
                chatID = id
                self.title = title
            }
            onChanged?()
        } catch {
            // Non-fatal: the conversation stays on screen even if the save fails.
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
}
