import SwiftUI
import OpenWebUIKit

/// The second-factor step of a sign-in (Open WebUI 0.13 `next_step`), drawn in
/// place of the login form.
///
/// - `verify`: the account has an authenticator — six digits, or a recovery code
///   for the person who lost the phone it lives on. Answered here, in the app.
/// - `enroll` / `recover`: the account has to set up (or set up again) its
///   authenticator, which needs the QR code, the recovery codes and the
///   operator's reset token — screens that belong to the web app. The browser
///   sign-in is the way to them when the server has it; otherwise the person is
///   told to finish in a browser and come back.
struct MFAChallengeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    let prompt: AppState.MFAPrompt
    /// `features.auth_sessions` — whether "continue in the browser" is on offer.
    let browserAvailable: Bool

    @State private var code = ""
    @State private var usingRecovery = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Verificação em duas etapas")
                .font(.ody(.title3).weight(.semibold))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)

            switch prompt.challenge.kind {
            case .verify: verifyForm
            case .enroll: browserStep(Text("Esta conta precisa configurar a verificação em duas etapas."),
                                      offline: Text("Esta conta precisa configurar a verificação em duas etapas. Faça isso pelo site do servidor, em um navegador, e depois entre aqui de novo."))
            case .recover: browserStep(Text("O administrador redefiniu a verificação em duas etapas desta conta."),
                                       offline: Text("O administrador redefiniu a verificação em duas etapas desta conta. Conclua a recuperação pelo site do servidor, em um navegador, e depois entre aqui de novo."))
            }

            if let message = prompt.message {
                Text(verbatim: message)
                    .font(.ody(.footnote))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("mfa.error")
            }

            Button("Cancelar") { app.cancelMFA() }
                // The code already sent is spent whether or not the person
                // stays; leaving mid-flight used to sign them in anyway.
                .disabled(app.loggingIn)
                .font(.ody(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .buttonStyle(.plain)
                .accessibilityIdentifier("mfa.cancel")
        }
        .onAppear { if prompt.challenge.kind == .verify { focused = true } }
    }

    // MARK: verify

    @ViewBuilder
    private var verifyForm: some View {
        Text(verbatim: usingRecovery ? L("Digite um dos seus códigos de recuperação.")
                                     : L("Digite o código de 6 dígitos do seu app autenticador."))
            .font(.ody(.footnote))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)

        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: usingRecovery ? L("Código de recuperação") : L("Código de verificação"))
                .font(.ody(.caption)).foregroundStyle(theme.secondaryText)
            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(usingRecovery ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
                .font(.ody(.body).monospacedDigit())
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(theme.border, lineWidth: 1))
                .accessibilityIdentifier("mfa.code")
        }

        Button(action: submit) {
            HStack {
                if app.loggingIn { ProgressView().tint(theme.onAccent) }
                Text("Verificar").font(.ody(.headline))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: Radius.control))
            .foregroundStyle(theme.onAccent)
        }
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.6)
        .accessibilityIdentifier("mfa.submit")

        Button(usingRecovery ? L("Usar o código do autenticador") : L("Usar um código de recuperação")) {
            usingRecovery.toggle()
            code = ""
            focused = true
        }
        .font(.ody(.subheadline))
        .foregroundStyle(theme.accent)
        .buttonStyle(.plain)
        .accessibilityIdentifier("mfa.recoveryToggle")
    }

    private var canSubmit: Bool {
        !app.loggingIn && !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        let entered = code, recovery = usingRecovery
        Task { await app.verifyMFA(code: entered, recovery: recovery) }
    }

    // MARK: enroll / recover

    @ViewBuilder
    private func browserStep(_ explanation: Text, offline: Text) -> some View {
        if browserAvailable {
            explanation
                .font(.ody(.footnote)).foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                app.cancelMFA()
                Task { await app.loginWithBrowser(provider: nil) }
            } label: {
                Text("Continuar no navegador").font(.ody(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: Radius.control))
                    .foregroundStyle(theme.onAccent)
            }
            .accessibilityIdentifier("mfa.continueInBrowser")
        } else {
            offline
                .font(.ody(.footnote)).foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }
}
