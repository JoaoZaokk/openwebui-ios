import SwiftUI
import OpenWebUIKit

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    @State private var email = ""
    @State private var password = ""
    @State private var showServerSheet = false
    @State private var sso: SSOProvider?
    /// Set when the system sheet signed in fine but this server would not take
    /// the result — the account has to be created through its own flow first.
    @State private var needsBrowser: SSOProvider?
    /// LDAP takes a directory username, not an email, so the form has to say which
    /// credential it is asking for.
    @State private var usingLDAP = false
    @FocusState private var focus: Field?

    enum Field { case email, pass }

    /// One SSO button, identified for `.sheet(item:)`.
    struct SSOProvider: Identifiable {
        let id: String
        let label: String
    }

    private var providers: [SSOProvider] {
        let all = app.serverFeatures?.oauthProviders.map { SSOProvider(id: $0.key, label: $0.label) } ?? []
        // A provider the whole country cannot reach would open onto a page that
        // never loads. Dropped only where that is true, and never down to nothing.
        return AppStorefront.reachableProviders(all, key: \.id,
                                                otherWaysIn: passwordAvailable || ldapAvailable)
    }
    /// Hidden until the server says it has LDAP, like the SSO buttons.
    private var ldapAvailable: Bool { app.serverFeatures?.ldapAvailable ?? false }
    /// A server can turn the password form off entirely and leave only SSO.
    private var passwordAvailable: Bool { app.serverFeatures?.passwordLoginAvailable ?? true }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            BackgroundDots().opacity(0.5)

            VStack(spacing: 22) {
                Spacer(minLength: 40)
                VStack(spacing: 10) {
                    BrandMark(size: 64)
                    Text("Open WebUI")
                        .font(.ody(.largeTitle, design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme.fg)
                    Text(serverLabel)
                        .font(.ody(.footnote, design: .monospaced))
                        .foregroundStyle(ServerConfig.isConfigured ? theme.secondaryText : theme.accent)
                        .onTapGesture { showServerSheet = true }
                }

                if passwordAvailable || usingLDAP {
                    VStack(spacing: 14) {
                        field(title: usingLDAP ? "Usuário" : "Email", text: $email, field: .email)
                            .textContentType(usingLDAP ? .username : .emailAddress)
                            .keyboardType(usingLDAP ? .default : .emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focus = .pass }

                        secureField(title: "Senha", text: $password, field: .pass)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                    .padding(.horizontal, 4)
                }

                if let err = app.loginError {
                    Text(err)
                        .font(.ody(.footnote, design: .monospaced))
                        .foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if passwordAvailable || usingLDAP {
                    Button(action: submit) {
                        HStack {
                            if app.loggingIn { ProgressView().tint(theme.onAccent) }
                            Text("Entrar").font(.ody(.headline, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(theme.onAccent)
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.6)
                }

                // Whatever else this server accepts. Drawn from `/api/config`, so a
                // server with no SSO configured shows nothing and nothing changes.
                VStack(spacing: 10) {
                    ForEach(providers) { p in
                        alternativeButton(L("Entrar com %@", p.label), icon: "person.badge.key") {
                            focus = nil
                            app.loginError = nil
                            // The system sheet when this provider can use it —
                            // it reuses Safari's session, so the account is
                            // already there. The web view otherwise.
                            if NativeSSO.isAvailable(provider: p.id) {
                                Task {
                                    // The web view is the fallback, not a dead
                                    // end: a server that will not take the
                                    // provider's token still signs people in
                                    // through its own flow. But it is a second
                                    // sign-in with nothing remembered, so say why
                                    // rather than dropping the user into it.
                                    if await app.loginWithNativeSSO(provider: p.id, anchor: nil) == .serverRefused {
                                        needsBrowser = p
                                    }
                                }
                            } else {
                                sso = p
                            }
                        }
                    }
                    if ldapAvailable && !usingLDAP {
                        alternativeButton(L("Entrar com LDAP"), icon: "building.2") {
                            focus = nil
                            app.loginError = nil
                            usingLDAP = true
                            email = ""; password = ""
                        }
                    }
                }
                .disabled(app.loggingIn || !ServerConfig.isConfigured)
                .opacity(app.loggingIn || !ServerConfig.isConfigured ? 0.6 : 1)

                Spacer()
            }
            .frame(maxWidth: 420)
            .padding(24)
        }
        .sheet(isPresented: $showServerSheet) { ServerSheet().environmentObject(app) }
        .sheet(item: $sso) { p in
            SSOWebLoginView(provider: p.id, label: p.label,
                            start: app.client.oauthLoginURL(provider: p.id),
                            isCompletion: { app.client.isOAuthCompletion($0) }) { result in
                switch result {
                case .success(let token): Task { await app.adoptSSO(token: token) }
                case .failure(let e):     app.loginError = e.errorDescription
                }
            }
            .environment(\.theme, theme)
        }
        .alert(L("Continuar"), isPresented: Binding(
            get: { needsBrowser != nil },
            set: { if !$0 { needsBrowser = nil } }
        ), presenting: needsBrowser) { p in
            Button("Cancelar", role: .cancel) { needsBrowser = nil }
            Button(L("Continuar")) { let provider = p; needsBrowser = nil; sso = provider }
        } message: { _ in
            Text("Esta conta ainda não entrou neste servidor. A primeira entrada precisa ser pelo navegador; depois disso o login é direto.")
        }
        .onAppear {
            if email.isEmpty { email = app.savedEmail ?? "" }
            // First run (no server saved yet) → prompt for it right away.
            if !ServerConfig.isConfigured { showServerSheet = true }
            else if app.serverFeatures == nil { Task { await app.loadServerFeatures() } }
        }
    }

    private var serverLabel: String {
        guard ServerConfig.isConfigured else { return L("Toque para definir seu servidor  ›") }
        let url = app.serverConfig.baseURL
        let label = url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
        return label + "  ›"
    }

    private var canSubmit: Bool {
        !app.loggingIn && !email.isEmpty && !password.isEmpty && ServerConfig.isConfigured
    }

    private func submit() {
        focus = nil
        let name = email.trimmingCharacters(in: .whitespaces)
        Task {
            if usingLDAP { await app.loginWithLDAP(user: name, password: password) }
            else { await app.login(email: name, password: password) }
        }
    }

    /// A sign-in route other than this server's password form.
    @ViewBuilder
    private func alternativeButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.ody(size: 13))
                Text(verbatim: title).font(.ody(.subheadline, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
            .foregroundStyle(theme.fg)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func field(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
            TextField("", text: text)
                .focused($focus, equals: field)
                .styledInput(theme)
        }
    }

    @ViewBuilder
    private func secureField(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
            SecureField("", text: text)
                .textContentType(.password)
                .focused($focus, equals: field)
                .styledInput(theme)
        }
    }
}

private extension View {
    func styledInput(_ theme: Theme) -> some View {
        self
            .font(.ody(.body, design: .monospaced))
            .foregroundStyle(theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
    }
}

/// Subtle dotted background matching the web login's "dots" pattern.
struct BackgroundDots: View {
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 20
            Canvas { ctx, size in
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        var c = ctx
                        c.translateBy(x: x, y: y)
                        c.fill(dot, with: .color(theme.fg.opacity(0.08)))
                        x += spacing
                    }
                    y += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
