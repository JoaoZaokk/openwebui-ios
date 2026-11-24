import AuthenticationServices
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
    /// Set while a sign-in the server stopped at a second-factor step waits for the
    /// person. The login screen swaps its form for the step.
    @Published var mfaPrompt: MFAPrompt? {
        // Every change of what the person is looking at is a new epoch: a verify
        // that was answered for a challenge they have since left (cancelled, or
        // the server changed) knows it by this number (Auth review #10/#11).
        didSet { mfaEpoch &+= 1 }
    }
    private var mfaEpoch = 0

    /// A sign-in that did not end in a session: the server wants a second factor
    /// (Open WebUI 0.13 `next_step`) before it will issue one.
    struct MFAPrompt: Equatable {
        var challenge: OWMFAChallenge
        /// What was typed to get here, kept to remember the account on success.
        var account: String?
        /// Why the screen is showing it, when a try already failed.
        var message: String?
    }

    let client: OpenWebUIClient
    let completions: ChatCompletionsClient
    /// Shared on-device cache of server chats (offline read + full-text search).
    let cache = ServerChatCache()
    private let keychain: OWKeychainStore

    /// Capabilities the server advertises (`GET /api/config`): which login methods
    /// exist, and whether plugins are on. nil until the login screen asks.
    @Published var serverFeatures: OWServerConfig?
    /// Why the model list is stale or empty, surfaced on the chat list.
    @Published var modelsError: String?
    /// Why the login screen could not read the server (blocked by the system,
    /// not allowed, unreachable) — said under the server name, where the person
    /// looks, instead of only when the sign-in button fails. nil when it answered.
    @Published var serverProbeError: String?
    /// The reason above is the Local Network switch: the login screen offers the
    /// Settings button next to it, because there is no deep link to that switch
    /// and "open Settings, find the app, find Local Network" is where people stop.
    var serverProbeNeedsSettings: Bool {
        serverProbeError == L("O iOS bloqueou o acesso à rede local. Em Ajustes › OpenWebUI, ligue Rede Local.")
    }

    private var sessionEnded: (any NSObjectProtocol)?

    init() {
        #if DEBUG
        keychain = ScreenshotRoute.keychain() ?? OWKeychainStore()
        #else
        keychain = OWKeychainStore()
        #endif
        let cfg = ServerConfig.load()
        self.serverConfig = cfg
        // The Keychain outlives the app; UserDefaults does not. After the app is
        // deleted and installed again the old token is still here while the
        // server it belongs to is gone, so the app skipped the login and talked
        // to the placeholder host — "Couldn't find that server", with the user
        // never asked for a server at all (App Review, 1.11, iPad). No saved
        // server means no session.
        if !ServerConfig.isConfigured { keychain.clear() }
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

    /// - Parameter reason: what the login screen says about why it appeared.
    ///   The default is the expired-session sentence, which is what the 401
    ///   notification means; a deliberate server switch passes nil — nothing
    ///   expired there, the user left.
    private func endSession(reason: String? = OWFailure.msg(OWError.notAuthenticated)) {
        guard phase == .main else { return }
        user = nil
        models = []
        cache.forgetOwner()
        // The login screen has a slot for the reason and used to get nothing —
        // the app just appeared there, as if it had crashed. The key already
        // exists in all 44 catalogues.
        loginError = reason
        phase = .login
    }

    /// The model list is what the composer needs; after an offline launch it is
    /// empty and nothing re-asked for it, so the send button stayed dead after
    /// the network came back. Pull-to-refresh and returning to the foreground
    /// both call this; it is a no-op once the list is there.
    func refreshModelsIfNeeded() async {
        guard phase == .main else { return }
        await refreshAccountIfNeeded()
        guard models.isEmpty else { return }
        await loadModels()
    }

    /// A launch with the server out of reach goes in on the offline cache with
    /// no profile (`user = nil`) and a config read without the sign-in, and
    /// nothing asked again: Ajustes lost "Usar memória" and the model got
    /// neither memory nor notes until the app was relaunched (report on build
    /// 28, during a weekend of network trouble). Called on every return to the
    /// foreground and when Ajustes opens; free once both are known.
    func refreshAccountIfNeeded() async {
        guard phase == .main, client.isAuthenticated else { return }
        if user == nil, let me = try? await client.me() {
            user = me
            adoptCacheOwner(claimingLegacy: true)
        }
        if serverFeatures?.features?.enableMemories == nil { await loadServerFeatures() }
    }

    /// Scopes the on-device cache to the account that just became known. The
    /// owner is recorded next to the token in the Keychain — same lifetime — so
    /// an offline launch can still open this account's cache.
    private func adoptCacheOwner(claimingLegacy: Bool) {
        guard let user else { return }
        let key = OpenWebUIClient.cacheOwner(origin: serverConfig.baseURL, userID: user.id)
        cache.adopt(owner: key, claimingLegacy: claimingLegacy)
        keychain.save(cacheOwner: key)
    }

    /// Asks the server what it offers before drawing the login screen.
    func loadServerFeatures() async {
        // Only if the app still points where this was asked. A slow answer from
        // the previous server landing after the switch would otherwise describe
        // that server's login methods on this one's login screen.
        let asked = serverConfig.baseURL
        var cfg: OWServerConfig?
        var why: String?
        do { cfg = try await client.serverConfig() }
        catch is CancellationError { return }
        catch { why = OWFailure.msg(error) }
        if serverConfig.baseURL == asked { serverProbeError = why }
        // A failed read keeps what was known. It used to blank it, and since 1.13
        // what is known includes what only a signed-in answer says (notes and
        // memory on or off): a hiccup on a refresh must not switch them off.
        if serverConfig.baseURL == asked, let cfg { serverFeatures = cfg }
    }

    /// 1.13 — what the model may see of the user's own data on the server.
    /// The rules are `OWPersonalContext`'s; this supplies what only the app
    /// knows: the signed-in config, the user, and the two switches in Ajustes.
    func sendsMemory() -> Bool {
        OWPersonalContext.sendsMemory(config: serverFeatures, user: user,
                                      setting: OWPersonalContext.setting(OWPersonalContext.memorySettingKey))
    }

    func offersNotes(toolIDs: [String] = [], serverWebSearch: Bool = false) -> Bool {
        OWPersonalContext.offersNotes(config: serverFeatures, user: user,
                                      setting: OWPersonalContext.setting(OWPersonalContext.notesSettingKey),
                                      toolIDs: toolIDs, serverWebSearch: serverWebSearch)
    }

    /// The two switches in Ajustes only make sense when the server has the
    /// feature and this user may use it.
    var memoryAvailable: Bool { (serverFeatures?.memoriesAvailable ?? false) && (user?.mayUseMemories ?? false) }
    var notesAvailable: Bool { (serverFeatures?.notesAvailable ?? false) && (user?.mayUseNotes ?? false) }

    /// `/api/config` read before sign-in lacks `enable_notes` / `enable_memories`
    /// (signed-in answer only); read it again now that there is a token.
    private func refreshFeaturesAfterSignIn() {
        Task { await loadServerFeatures() }
    }

    /// Pre-fill the login field with the last email used.
    var savedEmail: String? { keychain.loadEmail() }

    /// On launch: if a persisted token is still valid, go straight to the app.
    ///
    /// `/api/config` is read either way. It is public, it is what tells the write
    /// paths whether this server merges history (0.11+) or replaces the whole chat
    /// blob, and it is what the login screen needs to know which ways in exist.
    /// Leaving it unread meant every session guessed.
    ///
    /// The three launch reads run side by side. They used to run one after the
    /// other, each on the 30 s session, so a server that was down — or behind a
    /// proxy answering 502 only after its own 30 s — held the splash for a minute
    /// and a half before the offline cache opened (measured 27/09, server
    /// restarting after an upgrade). Now the wait is the slowest one, and the
    /// offline branch opens the cache before asking for the model list again.
    func bootstrap() async {
        let storefront = Task { await AppStorefront.refresh() }
        let features = Task { await loadServerFeatures() }
        guard client.isAuthenticated else {
            await storefront.value
            await features.value
            phase = .login
            return
        }
        do {
            user = try await client.me()
            // The token that answered is the one persisted before this launch —
            // the account that wrote any rows from before the cache was scoped.
            adoptCacheOwner(claimingLegacy: true)
            await features.value
            await loadModels()
            phase = .main
            await flushPendingChats()
        } catch is CancellationError {
        } catch OWError.notAuthenticated {
            // The server said the token is dead. `endSession` cannot say so from
            // here — it guards on `.main` — so the reason is set by hand.
            loginError = OWFailure.msg(OWError.notAuthenticated)
            phase = .login
        } catch {
            // No network, or the server is down. That is not "the token is dead",
            // and treating it as one sent the user to the login screen with a
            // valid token in the Keychain and an offline cache they could no
            // longer open — every cached conversation and the local search live
            // behind `.main`. Go in without a profile; the chat list explains the
            // failed load, and the next authenticated request that meets a real
            // 401 still routes back to login.
            user = nil
            if let last = keychain.loadCacheOwner() {
                cache.adopt(owner: last, claimingLegacy: true)
            } else {
                // An install from before the cache was scoped, first launched
                // offline: its rows are its own, readable until a launch that
                // can name the account claims them.
                cache.enterLegacyScope()
            }
            phase = .main
            await loadModels()
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
                    do {
                        try await client.syncChatTree(id: serverID, title: chat.title,
                                                      models: [model], tree: nodes, currentId: leaf)
                    } catch OWError.http(404, _) {
                        // Deleted on the server while the turn waited. The words
                        // are still the user's: create the conversation afresh.
                        _ = try await client.createChatTree(title: chat.title, models: [model],
                                                            tree: nodes, currentId: leaf)
                    }
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
            await conclude(try await client.signInResult(email: email, password: password), account: email)
        } catch {
            loginError = Self.signInMessage(error)
        }
    }

    /// What the sign-in screen says for a failure. A 409 from the server — the
    /// password or the session stamp changed while the sign-in was under way —
    /// has one meaning, and it is "start over".
    static func signInMessage(_ error: Error) -> String {
        if case OWError.http(409, let detail) = error {
            return OWMFAFailure.classify(status: 409, detail: detail).message
        }
        return OWFailure.msg(error)
    }

    /// Takes the answer of any sign-in route to where it leads: a session becomes
    /// the signed-in state; a second-factor step becomes a prompt; `pending` — an
    /// account waiting for an administrator — becomes a sentence.
    private func conclude(_ result: OWSignInResult, account: String?) async {
        switch result {
        case .session(let s):
            user = OWUser(session: s)
            await finishSignIn(account: account)
        case .mfa(let challenge):
            mfaPrompt = MFAPrompt(challenge: challenge, account: account, message: nil)
        case .pending:
            loginError = OWFailure.msg(OWError.pendingApproval)
        }
    }

    /// What every sign-in does once the server has accepted it: scope the cache
    /// to the account, remember who it was, load what the app opens on.
    private func finishSignIn(account: String?) async {
        adoptCacheOwner(claimingLegacy: false)
        if let account = account ?? user?.email, !account.isEmpty {
            keychain.saveCredentials(email: account, password: nil)   // remember the account only
        }
        mfaPrompt = nil
        await loadModels()
        phase = .main
        refreshFeaturesAfterSignIn()
        await flushPendingChats()
    }

    /// Answers the second-factor step with an authenticator code, or with a
    /// recovery code.
    func verifyMFA(code: String, recovery: Bool) async {
        guard let prompt = mfaPrompt, prompt.challenge.kind == .verify else { return }
        let epoch = mfaEpoch
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            let verified = try await client.verifyMFA(challenge: prompt.challenge, code: code, recovery: recovery)
            guard epoch == mfaEpoch else {
                // The person backed out of this challenge while the code was in
                // the air, and the server accepted it anyway. They are not
                // signed in as far as they know — make that true, instead of
                // jumping to the main screen over a Cancelar (Auth review #10).
                // (A server switch never gets here: the client discards that
                // answer itself.)
                await client.signOut()
                return
            }
            user = verified
            await finishSignIn(account: prompt.account)
        } catch let e as OWMFAError {
            // An answer for a challenge that is no longer on screen has nothing
            // to say to the screen that is (Auth review #10/#11).
            guard epoch == mfaEpoch else { return }
            if e.failure.endsChallenge {
                // The challenge is spent or gone: a new one needs a new sign-in.
                mfaPrompt = nil
                loginError = e.failure.message
            } else {
                mfaPrompt?.message = e.failure.message
            }
        } catch is CancellationError {
        } catch {
            guard epoch == mfaEpoch else { return }
            mfaPrompt?.message = OWFailure.msg(error)
        }
    }

    /// Leaves the second-factor step and goes back to the form.
    func cancelMFA() {
        mfaPrompt = nil
        loginError = nil
    }

    /// Signs in through the system browser (`features.auth_sessions`): Safari's
    /// own session, passkeys and password manager, which a web view has none of
    /// (issue #13). `provider` is the key of the SSO button the person tapped, or
    /// nil for the general "Entrar pelo navegador".
    func loginWithBrowser(provider: String?) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        let host = LoopbackBrowserHost()
        do {
            user = try await client.signInThroughBrowser(
                host: host, deviceName: OWBrowserSignIn.requestName(deviceLabel: BugReport.deviceLabel),
                provider: provider)
            await finishSignIn(account: nil)
        } catch is CancellationError {
            // The person closed the browser. Not a failure, and nothing to say.
        } catch {
            loginError = Self.signInMessage(error)
        }
    }

    /// What happened when the system sheet was tried.
    enum NativeSSOOutcome {
        case signedIn
        /// The user closed the sheet. Not a failure, and nothing to say.
        case cancelled
        /// The provider is happy but this server will not take its token — the
        /// exchange is switched off, or the account has never signed in through a
        /// browser and so does not exist yet. Both are recoverable by the web-view
        /// path, which the server does support and which can create the account.
        case serverRefused
        /// Something else, already reported in `loginError`.
        case failed
    }

    /// Signs in through the system sheet, then trades the provider's token for a
    /// session. The caller decides what to do with the outcome, because only it
    /// can offer the other path.
    func loginWithNativeSSO(provider: String, anchor: ASPresentationAnchor?) async -> NativeSSOOutcome {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            let providerToken = try await NativeSSO.signIn(provider: provider, anchor: anchor)
            let result = try await client.exchangeOAuthTokenResult(provider: provider, providerToken: providerToken)
            await conclude(result, account: nil)
            // A second-factor step or an unapproved account is not a failure, and
            // is already on screen; only a session is "signed in".
            return phase == .main ? .signedIn : .failed
        } catch is CancellationError {
            return .cancelled
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return .cancelled
        } catch OWError.http(403, _) {
            // Every 403 the exchange can answer means "not through this door":
            // disabled by the admin, an untrusted client, or an account that has
            // to be created in a browser first. Sending the user back to the
            // sheet's error would strand them; the web view gets them in.
            return .serverRefused
        } catch {
            loginError = Self.signInMessage(error)
            return .failed
        }
    }

    /// Finishes an SSO sign-in with the session the browser flow handed back.
    func adoptSSO(token: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            user = try await client.adopt(token: token)
            await finishSignIn(account: nil)
        } catch {
            loginError = OWFailure.msg(error)
        }
    }

    func loginWithLDAP(user name: String, password: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            await conclude(try await client.signInLDAPResult(user: name, password: password), account: name)
        } catch {
            loginError = Self.signInMessage(error)
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
        cache.forgetOwner()
        loginError = nil
        mfaPrompt = nil
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
            modelsError = OWFailure.msg(error)
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
                              available: chatModels.map(\.id))
    }

    /// The models a conversation can be sent to.
    ///
    /// A Gemini or OpenAI key puts the provider's whole catalogue on
    /// `/api/models` — speech, Imagen/DALL·E, Veo/Sora, embeddings, live audio —
    /// and every one of those fails the moment it is chatted with. A new chat
    /// used to open on whichever came first. If sorting leaves nothing (a
    /// server whose ids fool the heuristic), everything is offered, as before.
    var chatModels: [OWModel] {
        let chat = models.filter { $0.kind.canChat }
        return chat.isEmpty ? models : chat
    }

    /// Everything else the server lists, grouped by what it is for, in a
    /// stable order.
    var otherModels: [(kind: OWModelKind, models: [OWModel])] {
        OWModelKind.allCases.filter { !$0.canChat }.compactMap { kind in
            let list = models.filter { $0.kind == kind }
            return list.isEmpty ? nil : (kind, list)
        }
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
        mfaPrompt = nil   // a challenge belongs to the server that issued it
        if !client.isAuthenticated { endSession(reason: nil) }
        loginError = nil
        Task { await loadServerFeatures() }
    }

    // Factories
    func makeChatStore() -> ChatStore { ChatStore(client: client, cache: cache) }
    func makeChatViewModel(chat: OWChatSummary?, temporary: Bool = false, folderID: String? = nil) -> ChatViewModel {
        let vm = ChatViewModel(client: client, completions: completions, chat: chat,
                               models: chatModels, defaultModel: defaultModel, temporary: temporary, cache: cache,
                               folderID: folderID)
        vm.serverSearches = { [weak self] in self?.serverFeatures?.webSearchAvailable ?? true }
        vm.sendsMemory = { [weak self] in self?.sendsMemory() ?? false }
        vm.offersNotes = { [weak self] ids, serverSearch in
            self?.offersNotes(toolIDs: ids, serverWebSearch: serverSearch) ?? false
        }
        return vm
    }
}
