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
    /// Why the tool list is empty, when it is empty for a reason. Its own slot:
    /// `error` is the chat's banner, which the picker sheet covers.
    @Published var toolsError: String?
    /// Whether the last tool fetch failed. Separate from `toolsError`, which the
    /// banner's X clears — dismissing the sentence must not restore the empty
    /// state's "no tools on this server", a claim that was never established.
    @Published private(set) var toolsFailed = false

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
    private var persistTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    /// Asks the server for the questions under the reply that just finished.
    private var followUpTask: Task<Void, Never>?
    /// Set by `failTurn`, so `closeTurn` knows the reply is an error, not an answer.
    private var turnFailed = false

    /// The last turn failed because the conversation no longer fits the model's
    /// context. The chat offers to summarize it (`summarizeAndRetry`).
    @Published private(set) var contextOverflow = false
    @Published private(set) var summarizing = false
    /// Stands in, toward the model, for every message up to `through`. The
    /// screen keeps them; only what is sent gets shorter.
    struct ContextSummary: Codable, Equatable { var text: String; var through: String }
    private(set) var contextSummary: ContextSummary? {
        didSet {
            guard let id = chatID else { return }
            let key = Self.summaryKey(id)
            if let c = contextSummary, let d = try? JSONEncoder().encode(c) {
                UserDefaults.standard.set(d, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
    private static func summaryKey(_ chatID: String) -> String { "chat.contextSummary." + chatID }

    /// The app went to the background while a reply was streaming.
    ///
    /// iOS suspends the app about 30 s later and the stream to the server dies
    /// with it. The server is not asked to keep the reply — the app saves the
    /// conversation itself — so a reply cut off that way was gone for good: the
    /// bubble read "⚠️ The connection dropped partway through." and that was
    /// what got saved (App Store review, 1.10: "Replies don't come through").
    private var leftMidReply = false
    private var appActive = true
    /// A reply cut off because the app was away, asked again once it is back.
    private var resumeTurn: (assistantID: String, model: String, files: [OWAttachment], query: String)?
    /// Replies already asked again — once each, so a server that is really
    /// down still ends in the usual error instead of a loop.
    private var resumedReplies: Set<String> = []
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
    /// Identity for an unsent copy of a chat the server has never seen.
    private let localDraftID = UUID().uuidString
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
        if let id = chat?.id, let d = UserDefaults.standard.data(forKey: Self.summaryKey(id)) {
            contextSummary = try? JSONDecoder().decode(ContextSummary.self, from: d)
        }
        self.title = chat?.title ?? (temporary ? L("Conversa temporária") : L("Nova conversa"))
        self.selectedModel = defaultModel
    }

    var isNewChat: Bool { chatID == nil }

    /// Whether the server has web search on. With "Buscar na web" off nothing
    /// is offered to the model — as on the web — but a model that writes out a
    /// search call anyway (Gemma does, with no tool and no answer) gets the
    /// search instead of having the call shown as its reply.
    var serverSearches: () -> Bool = { true }

    /// Ajustes › Conversa › "Sugestões de continuação". On by default, as
    /// `autoFollowUps` is on the web.
    static let followUpsKey = "chat.followUps"
    static var followUpsEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: followUpsKey) == nil ? true : d.bool(forKey: followUpsKey)
    }

    /// The questions to offer: only under the last reply of the branch on
    /// screen, and only once it has finished — what the web shows.
    var followUps: [String] {
        guard !isStreaming, let last = messages.last, last.role == .assistant else { return [] }
        return last.followUps
    }

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
                    self.error = OWFailure.msg(error)
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

        for var n in serverNodes {
            // Questions shown before their save landed: a refresh in between
            // must not take them off the screen.
            if n.followUps.isEmpty, let local = tree[n.id]?.followUps, !local.isEmpty { n.followUps = local }
            tree[n.id] = n
        }
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

    /// By position, not by value: the same photo attached twice is two equal
    /// `data:` URLs, and removing "the one equal to this" took both.
    func removePendingImage(at index: Int) {
        guard pendingImageURLs.indices.contains(index) else { return }
        pendingImageURLs.remove(at: index)
    }
    func removePendingDocument(_ att: OWAttachment) { pendingDocuments.removeAll { $0.id == att.id } }

    /// Upload raw data and stage it as a document attachment.
    private func uploadAndAttach(_ data: Data, filename: String, mime: String, displayName: String? = nil) async {
        uploading = true; defer { uploading = false }
        do {
            let f = try await client.uploadFile(data: data, filename: filename, mime: mime)
            pendingDocuments.append(OWAttachment(type: "file", id: f.id, name: displayName ?? f.filename))
        } catch {
            self.error = OWFailure.msg(error)
        }
    }

    /// Attaches a file the user picked — from the file browser or the share sheet.
    ///
    /// A picture picked this way used to be uploaded as a plain document: it drew a
    /// grey "image.png" pill instead of the photo, and, worse, the model never saw
    /// it — documents go to the server as RAG context, and only `imageURLs` become
    /// `image_url` parts in the request. So the model answered questions about an
    /// image it had never been shown. Route pictures down the same path as the
    /// photo picker; fall back to uploading if the bytes don't decode as an image.
    func addDocument(data: Data, filename: String, mime: String) async {
        let looksLikeImage = mime.lowercased().hasPrefix("image/")
            || OWAttachment(type: "file", name: filename).isImage
        if looksLikeImage, let url = AttachImage.dataURL(from: data) {
            pendingImageURLs.append(url)
            return
        }
        await uploadAndAttach(data, filename: filename, mime: mime)
    }

    /// Attach a note's markdown as a document (RAG).
    ///
    /// The note is read again by id first. The picker lists notes through
    /// `GET /api/v1/notes/`, which cuts every body at 1000 characters
    /// (`_truncate_note_data`, backend routers/notes.py:42), so attaching the
    /// listed object handed the model the opening of a long note and nothing
    /// else — silently, since the attachment pill looks the same either way.
    func attachNote(_ note: OWNote) async {
        uploading = true; defer { uploading = false }
        do {
            let whole = try await client.note(note.id)
            let md = "# \(whole.title)\n\n\(whole.markdown)"
            await uploadAndAttach(Data(md.utf8), filename: "nota.md", mime: "text/markdown",
                                  displayName: whole.title)
        } catch {
            self.error = OWFailure.msg(error)
        }
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
            self.error = OWFailure.msg(error)
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
            self.error = OWFailure.msg(error)
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
        // A retry starts clean: the previous attempt's sentence over this
        // attempt's spinner said the retry had already failed.
        toolsError = nil
        Task {
            defer { loadingTools = false }
            do {
                let list = try await client.tools()
                toolsFailed = false
                availableTools = list
                // Drop selections for tools this account lost access to, so we never
                // send a tool_id the server will reject.
                let ids = Set(list.map(\.id))
                selectedToolIDs.formIntersection(ids)
            } catch is CancellationError {
            } catch {
                toolsError = OWFailure.msg(error)
                toolsFailed = true
            }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImageURLs
        let docs = pendingDocuments
        guard (!text.isEmpty || !images.isEmpty || !docs.isEmpty),
              !isStreaming, !isPersisting, let model = selectedModel else { return }
        contextOverflow = false
        input = ""; pendingImageURLs = []; pendingDocuments = []
        submit(text, images: images, docs: docs, model: model)
    }

    /// A tapped suggestion goes out as the next message, as on the web. What the
    /// user was typing, and anything staged, stays where it is.
    func sendFollowUp(_ question: String) {
        guard !isStreaming, !isPersisting, let model = selectedModel else { return }
        submit(question, images: [], docs: [], model: model)
    }

    private func submit(_ text: String, images: [String], docs: [OWAttachment], model: String) {
        error = nil
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
        turnFailed = false
        leftMidReply = !appActive
        followUpTask?.cancel()   // questions for a reply that is no longer the last
        beginBackgroundHold()   // let the reply finish if the user backgrounds the app

        // Context = the active branch except the empty assistant we stream into,
        // with a summary in place of the turns it covers.
        var convo = Self.withSummary(contextSummary, Array(messages.dropLast()))
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
        // Every exit — [DONE], a stream that simply stopped, a thrown error, Stop
        // during the reply, Stop during the web search — closes the turn the same
        // way. The web-search cancellation used to `return` past the close: the
        // "Pesquisando…" pill stayed, the blank assistant node was persisted as
        // the leaf, and in a new conversation the question itself never reached
        // the server, because the save only ran at the end of this function.
        defer { closeTurn(assistantID, sawText: sawText) }
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
            // Already searched for this turn (or the server's search just
            // failed): a call the model writes anyway is only cut.
            let search = OWReplySearch(offer: false, mayRun: !webSearch && serverSearches())
            var finished = false
            for try await update in completions.streamReply(model: model, messages: convo, files: streamFiles,
                                                            options: options, search: search) {
                awaitingWebSearch = false
                switch update {
                case .searching:
                    awaitingWebSearch = true
                case .searchFailed(let why):
                    self.error = why
                case .toolCall:
                    break
                case .textDelta(let d):
                    sawText = true
                    append(assistantID, d)
                case .reasoningDelta(let d):
                    appendReasoning(assistantID, d)
                case .sources(let list):
                    // After the app's own search the server sends a frame named
                    // after the query, with no addresses: it must not replace
                    // the sites already listed.
                    if let i = index(of: assistantID),
                       messages[i].sources.isEmpty || list.contains(where: { $0.url?.hasPrefix("http") == true }) {
                        messages[i].sources = list
                    }
                case .error(let msg):
                    failTurn(assistantID, msg)
                case .done:
                    finished = true
                }
            }
            // A suspended app's stream can also just stop, with no error and no
            // `[DONE]`: half a reply that would be saved as if it were whole.
            if !finished, !turnFailed, leftMidReply, !Task.isCancelled,
               !resumedReplies.contains(assistantID) {
                resumeTurn = (assistantID, model, files, query)
            }
        } catch is CancellationError {
            // user stopped — keep whatever streamed so far
        } catch let e as URLError where leftMidReply && e.code != .cancelled
                                        && !resumedReplies.contains(assistantID) {
            // Cut off by the trip to the background, not by the server: asked
            // again when the app is back (`closeTurn` holds it until then).
            resumeTurn = (assistantID, model, files, query)
        } catch {
            failTurn(assistantID, OWFailure.msg(error))
        }
    }

    // MARK: - Leaving the app mid-reply

    func appWentToBackground() {
        appActive = false
        if isStreaming { leftMidReply = true }
    }

    func appBecameActive() {
        appActive = true
        if resumeTurn != nil, !isStreaming { resumeCutOffReply() }
    }

    /// Asks the cut-off question again, into the same reply. Whatever had
    /// streamed before the cut is replaced by the whole answer.
    private func resumeCutOffReply() {
        guard let r = resumeTurn else { return }
        resumeTurn = nil
        resumedReplies.insert(r.assistantID)
        guard let i = index(of: r.assistantID), i == messages.count - 1 else { return }
        messages[i].content = ""
        messages[i].reasoning = ""
        messages[i].sources = []
        startAssistantTurn(model: r.model, assistantID: r.assistantID, files: r.files, query: r.query)
    }

    /// The one way a turn ends, whatever ended it. Runs from `runStream`'s
    /// `defer`, so no exit path can skip it.
    private func closeTurn(_ assistantID: String, sawText: Bool) {
        // Cut off while the app was away: nothing is stamped and nothing is
        // saved — the reply is asked again (now, or when the app is back).
        if resumeTurn?.assistantID == assistantID {
            awaitingWebSearch = false
            isStreaming = false
            endBackgroundHold()
            if appActive { Task { @MainActor [weak self] in self?.resumeCutOffReply() } }
            return
        }
        // A reply that is only reasoning still said something — the disclosure
        // shows it, so don't stamp it "(no response)" (which would then be
        // persisted over a real turn).
        if !sawText, let i = index(of: assistantID),
           messages[i].content.isEmpty, messages[i].reasoning.isEmpty {
            if Task.isCancelled {
                // Stopped before the first token. A cancelled SSE stream ends
                // cleanly rather than throwing, so this landed here and stamped
                // the placeholder — which `schedulePersist()` then wrote to the
                // server as the assistant's answer, and every later load showed
                // "_(sem resposta)_" as a real turn. There is no reply to keep.
                discardEmptyTurn(assistantID)
            } else {
                messages[i].content = L("_(sem resposta)_")
            }
        }
        // The reply streamed into `messages`; the tree only learned it in
        // `persist()`, which a temporary chat skips. Its next send, regenerate
        // or branch switch rebuilt the screen from the tree and blanked every
        // earlier answer.
        syncBranchIntoTree()
        awaitingWebSearch = false
        isStreaming = false
        notifyReplyIfBackgrounded(assistantID)
        endBackgroundHold()
        // Ask for notification permission only once the first reply has landed —
        // asking at send time throws the system alert over a streaming answer.
        askForNotificationsOnce()
        // Read before anything below can await: Stop is a cancelled stream task.
        let answered = sawText && !Task.isCancelled && !turnFailed
        schedulePersist()
        if answered, Self.followUpsEnabled { suggestFollowUps(after: assistantID) }
    }

    /// Asks the server for the questions to offer under `replyID`, shows them,
    /// and keeps them on the reply's node where the web reads them.
    ///
    /// Asked right away rather than after the save, so they show up as soon as
    /// the task model answers; only the write waits. It goes on the save chain:
    /// a full-chat write fetched before the questions existed and landing after
    /// them would put the node back without them.
    private func suggestFollowUps(after replyID: String) {
        guard let end = index(of: replyID) else { return }
        let model = messages[end].model ?? selectedModel
        guard let model else { return }
        let convo = messages[...end].map { OWChatMessageInput(role: $0.role.rawValue, text: $0.content) }
        followUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let list = try? await self.client.generateFollowUps(model: model, messages: convo,
                                                                       chatID: self.chatID),
                  !list.isEmpty, !Task.isCancelled else { return }
            self.tree[replyID]?.followUps = list
            if let i = self.index(of: replyID) { self.messages[i].followUps = list }
            guard !self.temporary else { return }   // shown, never saved
            let previous = self.persistTask
            self.persistTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, let id = self.chatID else { return }
                try? await self.client.saveFollowUps(list, replyID: replyID, chatID: id)
            }
        }
    }

    /// Saves outside `streamTask`.
    ///
    /// The save used to be the last statement of the stream body, which meant Stop
    /// cancelled it too: `streamTask.cancel()` marks the task, `URLSession` then
    /// refuses the very first request, and the turn the user had just watched
    /// arrive never reached the server — with a raw `CancellationError` in the
    /// error banner as the only sign. Stopping a reply means stop *generating*,
    /// not discard. An unstructured `Task` does not inherit cancellation, and
    /// chaining onto the previous one keeps two saves from racing on the same chat.
    private func schedulePersist() {
        let previous = persistTask
        persistTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.persist()
        }
    }

    /// One policy for a turn that failed, wherever the failure came from.
    ///
    /// A failure mid-stream arrives two ways — as a `data: {"error": …}` frame, or
    /// as a thrown error — and the two disagreed. The thrown path kept whatever had
    /// already streamed and put the reason in the banner; the frame path called
    /// `setContent`, **replacing** the reply with the error text. So a model that
    /// wrote three paragraphs and then hit a provider error lost all three, and
    /// `schedulePersist()` right after wrote that loss to the server. Whatever
    /// arrived is the user's: an error never overwrites it.
    private func failTurn(_ assistantID: String, _ raw: String) {
        turnFailed = true
        // Offered only with something before the question to summarize: a
        // first message past the context is too long by itself.
        contextOverflow = Self.isContextOverflow(raw)
            && (messages.lastIndex(where: { $0.role == .user }) ?? 0) > 0
        let msg = friendlyError(raw)
        if let i = index(of: assistantID), messages[i].content.isEmpty {
            messages[i].content = "⚠️ \(msg)"
        } else {
            self.error = msg
        }
    }

    // MARK: - Context summary

    /// The wording providers use for a request longer than the model's context
    /// (OpenAI, Anthropic, Gemini, llama.cpp, Ollama, LM Studio, vLLM; GLM's
    /// "Prompt exceeds max length", seen for real on 2026-10-28; and the kit's
    /// `OWStreamUpdate.contextFull` for a reply closed before it began).
    static func isContextOverflow(_ raw: String) -> Bool {
        let l = raw.lowercased()
        return ["context length", "context_length", "context window", "maximum context",
                "prompt is too long", "input is too long", "too many tokens", "exceeds the context",
                "exceed context", "reduce the length", "token limit", "n_ctx", "num_ctx",
                "exceeds max length", "exceeds maximum length", "exceeds the maximum length"]
            .contains { l.contains($0) }
    }

    /// The turns sent to the model: the summary, when there is one and its last
    /// message is still on this branch, replaces everything up to it and rides
    /// on the first question after it. Not a turn of its own: several chat
    /// templates (Gemma's among them) reject two user turns in a row or a
    /// system turn anywhere but first.
    static func withSummary(_ summary: ContextSummary?, _ msgs: [OWMessage]) -> [OWChatMessageInput] {
        guard let summary, let cut = msgs.firstIndex(where: { $0.id == summary.through }),
              cut + 1 < msgs.count else { return msgs.map { OWChatMessageInput($0) } }
        var rest = msgs[(cut + 1)...].map { OWChatMessageInput($0) }
        let note = "(Summary of the earlier part of this conversation:\n\(summary.text))\n\n"
        if rest[0].role == "user" { rest[0].text = note + rest[0].text }
        else { rest.insert(OWChatMessageInput(role: "user", text: note), at: 0) }
        return rest
    }

    /// Characters per summary request — about 3–4k tokens, which every model
    /// that can chat at all takes.
    static let summaryPieceLimit = 12_000

    /// The turns as a transcript, cut into pieces of at most `summaryPieceLimit`.
    /// A message longer than a piece keeps its start and its end.
    static func summaryPieces(_ turns: [OWChatMessageInput]) -> [String] {
        let room = summaryPieceLimit - 40
        var pieces: [String] = [], current = ""
        for t in turns {
            var body = t.text
            if body.count > room {
                body = String(body.prefix(room / 2 - 10)) + "\n[…]\n" + String(body.suffix(room / 2 - 10))
            }
            let line = (t.role == "user" ? "User: " : "Assistant: ") + body + "\n\n"
            if !current.isEmpty, current.count + line.count > summaryPieceLimit {
                pieces.append(current); current = ""
            }
            current += line
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Summarizes the turns before the question that overflowed — on top of an
    /// earlier summary, piece by piece so no request overflows in turn — then
    /// asks that question again.
    func summarizeAndRetry() async {
        guard contextOverflow, !summarizing, !isStreaming,
              let failed = messages.last, failed.role == .assistant,
              let qi = messages.lastIndex(where: { $0.role == .user }), qi > 0,
              let model = failed.model ?? selectedModel else { return }
        let through = messages[qi - 1].id
        var older = Array(messages[..<qi])
        var running = ""
        if let s = contextSummary, let cut = older.firstIndex(where: { $0.id == s.through }) {
            running = s.text
            older = Array(older[(cut + 1)...])
        }
        summarizing = true
        defer { summarizing = false }
        error = nil
        do {
            for piece in Self.summaryPieces(older.map { OWChatMessageInput(role: $0.role.rawValue, text: $0.content) }) {
                running = try await summarize(piece, onTopOf: running, model: model)
            }
        } catch {
            self.error = L("Não foi possível resumir a conversa.")
            return
        }
        guard !running.isEmpty else { self.error = L("Não foi possível resumir a conversa."); return }
        contextSummary = ContextSummary(text: running, through: through)
        contextOverflow = false
        // The failed turn was being saved; `regenerate` does nothing while a
        // save runs, and the question was silently not asked again.
        await persistTask?.value
        regenerate(messageID: failed.id)
    }

    private func summarize(_ transcript: String, onTopOf earlier: String, model: String) async throws -> String {
        var ask = "Summarize the conversation below so that it can be continued without it. Keep names, numbers, decisions, open questions and what the user asked for or prefers. Write in the language of the conversation, in at most 300 words, and nothing but the summary."
        if !earlier.isEmpty { ask += "\n\nSummary of what came before it:\n" + earlier }
        ask += "\n\nConversation:\n" + transcript
        var out = ""
        for try await u in completions.streamReply(model: model, messages: [OWChatMessageInput(role: "user", text: ask)],
                                                   search: .off) {
            switch u {
            case .textDelta(let t): out += t
            case .error(let e): throw OWError.decoding(e)
            default: break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map raw server errors to clearer pt-BR messages.
    private func friendlyError(_ msg: String) -> String {
        let l = msg.lowercased()
        if Self.isContextOverflow(msg) {
            return L("Esta conversa passou do limite de contexto do modelo. Resuma a conversa para continuar.")
        }
        if l.contains("image input") || l.contains("support image") || l.contains("no endpoints found that support image") {
            return L("Este modelo não tem visão (não aceita imagens). Escolha um modelo com visão para enviar imagens.")
        }
        return msg
    }

    /// Saves the conversation to the server (creates on the first turn, appends after).
    /// Where an unsent copy of this conversation lives until the server takes it.
    /// Stable for the life of the view model, so retrying overwrites the draft
    /// rather than stacking copies of it.
    private var pendingID: String {
        chatID.map(PendingChat.idForSync) ?? PendingChat.idForNew(localDraftID)
    }

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
                cache?.deleteCached(id: PendingChat.idForSync(id))
            } else {
                let id = try await client.createChatTree(title: title, models: [model],
                                                         tree: Array(tree.values), currentId: currentLeafId)
                cache?.deleteCached(id: PendingChat.idForNew(localDraftID))
                chatID = id
                self.title = title
                onChanged?()
                await autoTitle(id: id, model: model)   // replace the first-message stub
                return
            }
            onChanged?()
        } catch {
            // The turn already streamed and the user already read it. Losing it
            // because the save failed — a dropped connection, a restarted server —
            // would erase something that visibly happened, so hold it on device and
            // push it on the next launch.
            let kept = cache?.keepPending(id: pendingID, title: title, models: [model],
                                          messages: Array(tree.values)) ?? false
            let reason = OWFailure.msg(error)
            // Only promise what happened: with no cache scope (a temporary session
            // shape, or a launch that could not name the account) nothing was kept,
            // and the reason alone is the honest banner.
            self.error = kept ? L("%@ A conversa está salva no aparelho e será enviada depois.", reason) : reason
        }
    }

    private func chatTitle() -> String {
        if chatID != nil { return title }   // keep an existing chat's title
        if let first = messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            return String(first.prefix(50))
        }
        return title
    }

    /// After the first exchange, ask the SERVER to name the conversation (it
    /// otherwise keeps the truncated first message as the title).
    ///
    /// The app does not write the title and does not invent one: the admin's task
    /// model, title template and "title generation" switch decide everything, the
    /// same way they do on the web. A disabled switch, an answer with no title
    /// object in it, or any error leaves the stub title in place — there is no
    /// local fallback. Runs once, right after the chat is created.
    private func autoTitle(id: String, model: String) async {
        // The reply is what must exist: the server's template names the topic from
        // the last two messages, and the user turn may be nothing but a photo or a
        // document. A reply that only thought out loud still said something —
        // `closeTurn` treats it as a real turn, so it can be titled too.
        guard let ai = messages.lastIndex(where: { $0.role == .assistant && !Self.replyText($0).isEmpty })
        else { return }
        var turn: [OWChatMessageInput] = []
        if let ui = messages[..<ai].lastIndex(where: { $0.role == .user }) {
            turn.append(OWChatMessageInput(role: "user", text: messages[ui].content))
        }
        turn.append(OWChatMessageInput(role: "assistant", text: Self.replyText(messages[ai])))
        do {
            guard let generated = try await client.generateTitle(model: model, messages: turn,
                                                                 chatID: id),
                  let clean = Self.cleanTitle(generated) else { return }
            self.title = clean
            // renameChat patches the title on the raw server JSON. updateChat would
            // rewrite the whole chat through our lossy model and drop whatever the
            // server keeps that we don't model (`output` text, sources, branches).
            try? await client.renameChat(id, to: clean)
            onChanged?()
        } catch is CancellationError {
            return   // the turn was abandoned; nothing to name
        } catch {
            return   // best effort: the stub title stays
        }
    }

    /// What an assistant turn can be named from: the visible reply, or the
    /// reasoning when the model only thought out loud.
    private static func replyText(_ m: OWMessage) -> String {
        m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? m.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            : m.content
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
        #if DEBUG
        if ScreenshotRoute.raw != nil { return }   // no system alert over a capture
        #endif
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
        schedulePersist()   // remember the active branch server-side
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

    /// Removes an assistant turn that never produced anything, and puts the leaf
    /// back under its parent so the next message hangs off the question instead
    /// of a blank node. The user's own message stays — they did send it.
    private func discardEmptyTurn(_ id: String) {
        let parent = tree[id]?.parentId
        tree.removeValue(forKey: id)
        messages.removeAll { $0.id == id }
        // The newest surviving descendant, not the bare parent. `rebuildActiveBranch`
        // only walks upward, so leaving the leaf on a node that still has children —
        // the reply a cancelled regenerate was replacing — hid that reply with no
        // branch control to bring it back, and the save then made the hidden leaf
        // the server's `currentId` as well. A plain send has no other child, so
        // it still lands on the question.
        if currentLeafId == id { currentLeafId = parent.map { leaf(from: $0) } }
        rebuildActiveBranch()
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
