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
        } catch {
            phase = .login
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

    func logout() async {
        await client.signOut()
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

    /// First available model id, used as the default for new chats.
    var defaultModel: String? { models.first?.id }

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
