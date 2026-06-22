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
    private let keychain = OWKeychainStore()

    init() {
        let cfg = ServerConfig.load()
        self.serverConfig = cfg
        let c = OpenWebUIClient(config: cfg.owConfig, tokens: keychain)
        self.client = c
        self.completions = ChatCompletionsClient(client: c)
    }

    /// Pre-fill the login field with the last email used.
    var savedEmail: String? { keychain.loadEmail() }

    /// On launch: if a persisted token is still valid, go straight to the app.
    func bootstrap() async {
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

    func loadModels() async {
        models = (try? await client.models()) ?? []
    }

    /// First available model id, used as the default for new chats.
    var defaultModel: String? { models.first?.id }

    func updateServer(_ url: URL) {
        var cfg = serverConfig
        cfg.baseURL = url
        cfg.save()
        serverConfig = cfg
        client.updateConfig(cfg.owConfig)
    }

    // Factories
    func makeChatStore() -> ChatStore { ChatStore(client: client) }
    func makeChatViewModel(chat: OWChatSummary?, temporary: Bool = false) -> ChatViewModel {
        ChatViewModel(client: client, completions: completions, chat: chat,
                      models: models, defaultModel: defaultModel, temporary: temporary)
    }
}
