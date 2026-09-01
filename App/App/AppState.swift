import SwiftUI
import OpenWebUIKit

@MainActor
final class AppState: ObservableObject {
    enum Phase { case launching, login, main }

    @Published var phase: Phase = .launching
    @Published var serverConfig: ServerConfig
    @Published var user: OWUser?
    @Published var models: [OWModel] = []

    // Login flow
    @Published var loginError: String?
    @Published var loggingIn = false

    let client: OpenWebUIClient
    let completions: ChatCompletionsClient
    /// Shared on-device cache of server chats (offline read + full-text search).
    let cache = ServerChatCache()
    private let keychain = OWKeychainStore()

    /// Capabilities the server advertises (`GET /api/config`): which login methods
    /// exist, and whether plugins are on. nil until the login screen asks.
    @Published var serverFeatures: OWServerConfig?
    /// Why the model list is stale or empty, surfaced on the chat list.
    @Published var modelsError: String?

    private var sessionEnded: (any NSObjectProtocol)?

    init() {
        let cfg = ServerConfig.load()
        self.serverConfig = cfg
        let c = OpenWebUIClient(config: cfg.owConfig, tokens: keychain)
        self.client = c
        self.completions = ChatCompletionsClient(client: c)
        // A token that dies mid-session used to leave every screen showing
        // "Sessão expirada" against a client that had already thrown the token
        // away — nothing routed back to login.
        sessionEnded = NotificationCenter.default.addObserver(
            forName: OpenWebUIClient.sessionEndedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession() }
        }
    }

    deinit { sessionEnded.map(NotificationCenter.default.removeObserver) }

    private func endSession() {
        guard phase == .main else { return }
        user = nil
        models = []
        phase = .login
    }

    /// Asks the server what it offers before drawing the login screen.
    func loadServerFeatures() async {
        serverFeatures = try? await client.serverConfig()
    }

    /// Pre-fill the login field with the last email used.
    var savedEmail: String? { keychain.loadEmail() }

    /// On launch: if a persisted token is still valid, go straight to the app.
    ///
    /// `/api/config` is read either way. It is public, it is what tells the write
    /// paths whether this server merges history (0.11+) or replaces the whole chat
    /// blob, and it is what the login screen needs to know which ways in exist.
    /// Leaving it unread meant every session guessed.
    func bootstrap() async {
        await loadServerFeatures()
        guard client.isAuthenticated else { phase = .login; return }
        do {
            user = try await client.me()
            await loadModels()
            phase = .main
            await flushPendingChats()
        } catch {
            phase = .login
        }
    }

    /// How many conversations are still waiting to reach the server. Drives the
    /// "resend" row — holding them silently is only half an answer; the user has to
    /// be able to see that something is waiting and push it themselves.
    @Published var pendingChatCount = 0
    @Published var resendingPending = false

    func refreshPendingCount() { pendingChatCount = cache.pendingChats().count }

    /// Pushes conversations the app is still holding because a save failed.
    ///
    /// Runs once the session is known good, and again whenever the user taps the
    /// resend row. Stops at the first failure rather than grinding through the
    /// queue: they all failed for the same reason a moment ago.
    func flushPendingChats() async {
        resendingPending = true
        defer { resendingPending = false; refreshPendingCount() }
        for chat in cache.pendingChats() {
            guard let model = chat.models.first ?? defaultModel else { continue }
            let nodes = chat.messages
            let leaf = OWChat.activeBranch(nodes, currentId: nil).last?.id
            do {
                if let serverID = PendingChat.serverID(of: chat.id) {
                    try await client.syncChatTree(id: serverID, title: chat.title,
                                                  models: [model], tree: nodes, currentId: leaf)
                } else {
                    _ = try await client.createChatTree(title: chat.title, models: [model],
                                                        tree: nodes, currentId: leaf)
                }
                cache.deleteCached(id: chat.id)
            } catch {
                return
            }
        }
    }

    func login(email: String, password: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            user = try await client.signIn(email: email, password: password)
            keychain.saveCredentials(email: email, password: nil)   // remember email only
            await loadModels()
            phase = .main
        } catch {
            loginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Finishes an SSO sign-in with the session the browser flow handed back.
    func adoptSSO(token: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            user = try await client.adopt(token: token)
            if let email = user?.email, !email.isEmpty {
                keychain.saveCredentials(email: email, password: nil)
            }
            await loadModels()
            phase = .main
            await flushPendingChats()
        } catch {
            loginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loginWithLDAP(user name: String, password: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            user = try await client.signInLDAP(user: name, password: password)
            keychain.saveCredentials(email: name, password: nil)
            await loadModels()
            phase = .main
            await flushPendingChats()
        } catch {
            loginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func logout() async {
        await client.signOut()
        // The identity provider's own cookies live in the web view, not in
        // URLSession — leaving them means the next "sign in with…" walks back into
        // the same account without asking.
        await SSOWebSession.clear()
        user = nil
        models = []
        phase = .login
    }

    /// The model list drives the composer: with none, the send button is disabled.
    /// Zeroing it on a transient failure therefore bricked the chat screen with no
    /// explanation anywhere. Keep what we had, and say what went wrong.
    func loadModels() async {
        do {
            models = try await client.models()
            modelsError = nil
        } catch is CancellationError {
        } catch {
            modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func lastModelKey(_ host: String) -> String { "openwebui.lastModel.\(host)" }
    private var lastModelKey: String {
        Self.lastModelKey(serverConfig.baseURL.host?.lowercased() ?? "")
    }

    /// The model a new chat opens with.
    ///
    /// This was `models.first` — whatever order the server happened to return —
    /// so every new chat dropped the model the user actually wanted and made them
    /// pick it again. ("Bei jedem neuen Chat neu auswählen nervt", App Store
    /// review, 1.7.) It now remembers the last model picked, keyed by host so
    /// pointing at another server doesn't ask for a model that one has never
    /// heard of, and only if this server still offers it — a model that was
    /// removed or lost its access control falls back to the first available.
    var defaultModel: String? {
        OWModelChoice.resolve(remembered: UserDefaults.standard.string(forKey: lastModelKey),
                              available: models.map(\.id))
    }

    /// Records an explicit pick from the model menu. Adopting an existing chat's
    /// model is not a pick — opening one old conversation must not redefine what
    /// every future chat starts with.
    func rememberModel(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastModelKey)
    }

    func updateServer(_ url: URL) {
        var cfg = serverConfig
        cfg.baseURL = url
        cfg.save()
        serverConfig = cfg
        // Dropping the old host's token is `updateConfig`'s job; ours is to notice
        // it happened, because the session on screen no longer has one.
        client.updateConfig(cfg.owConfig)
        serverFeatures = nil
        if !client.isAuthenticated { endSession() }
        Task { await loadServerFeatures() }
    }

    // Factories
    func makeChatStore() -> ChatStore { ChatStore(client: client, cache: cache) }
    func makeChatViewModel(chat: OWChatSummary?, temporary: Bool = false) -> ChatViewModel {
        ChatViewModel(client: client, completions: completions, chat: chat,
                      models: models, defaultModel: defaultModel, temporary: temporary, cache: cache)
    }
}
