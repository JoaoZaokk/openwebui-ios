#if os(iOS)
import SwiftUI
import UIKit
import LocalAuthentication
import OpenWebUIKit

// Face ID / Touch ID / passcode lock (1.13). The decisions (when to lock, when
// to cover, the grace) are `AppLockPolicy` in the kit, with tests; this file is
// the part that needs a device: LocalAuthentication, one UIWindow per scene and
// the scene notifications.
//
// Why a UIWindow and not a SwiftUI overlay on RootView: the app presents 29
// sheets / full-screen covers (Settings and the voice screen among them), and a
// presentation is a separate UIKit layer that sits ABOVE anything SwiftUI draws
// in the root view. With Settings open, an overlay would leave it fully readable
// in the app switcher snapshot, which is the very leak this feature exists to
// close. A window at `.alert + 1` is above every presentation, the keyboard and
// UIAlertController alerts, and it needs no cooperation from the screens under it.
//
// Why UIScene notifications and not `scenePhase`: they are posted synchronously
// as the scene changes state, so the cover window is already visible when the
// system takes the snapshot; an `onChange` runs a SwiftUI update later.

/// What the device offers to authenticate with, for the labels.
enum AppLockMethod: Equatable {
    case faceID, touchID, opticID, passcode

    /// Biometrics when they are usable now, the device passcode otherwise. Not
    /// enrolled biometrics is "passcode" on purpose: that is what will be asked.
    static func current() -> AppLockMethod {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .passcode }
        switch ctx.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default:       return .passcode
        }
    }

    var symbol: String {
        switch self {
        case .faceID:   return "faceid"
        case .touchID:  return "touchid"
        case .opticID:  return "opticid"
        case .passcode: return "lock.fill"
        }
    }

    /// One literal per variant, so each is its own catalogue key and can be
    /// translated with the right grammar (a template with the name spliced in
    /// would not survive every language).
    @ViewBuilder var settingsTitle: some View {
        switch self {
        case .faceID:   Text("Bloquear com Face ID")
        case .touchID:  Text("Bloquear com Touch ID")
        case .opticID:  Text("Bloquear com Optic ID")
        case .passcode: Text("Bloquear com o código do aparelho")
        }
    }
}

/// Outcome of one LocalAuthentication round. Lives in the kit because what each
/// ending means for the lock (`.unavailable` turns it off) is decided there.
typealias AppLockAuthResult = AppLockPolicy.AuthOutcome

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    static let enabledKey = "security.appLock"

    @Published private(set) var policy: AppLockPolicy {
        didSet { if policy != oldValue { applyWindows() } }
    }
    @Published private(set) var method: AppLockMethod = .passcode
    /// Set when the lock switched itself off because the device can no longer
    /// authenticate (passcode removed), so Settings can say why it is off.
    /// Review finding #19: nobody may be locked out of their own chats.
    @Published private(set) var turnedOffByUnavailability = false

    var isEnabled: Bool { policy.isEnabled }

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var scenePhases: [ObjectIdentifier: AppLockPolicy.Phase] = [:]
    private var observers: [NSObjectProtocol] = []
    /// One automatic prompt per stay in the foreground. Without it, cancelling
    /// the system sheet brings the scene back to `.active`, which would raise the
    /// sheet again, forever; the button is always there for the next try.
    private var autoPromptArmed = true

    private init() {
        policy = AppLockPolicy(enabled: Self.storedEnabled)
    }

    /// Launch arguments that open a screen for a capture or a UI test
    /// (`-screenshotRoute`) never meet the lock: those runs start signed in to a
    /// stub and have nobody to put a finger on the sensor. Debug builds only;
    /// `-appLockInCaptures YES` brings the lock back for testing the lock itself.
    private static var storedEnabled: Bool {
        #if DEBUG
        if ScreenshotRoute.raw != nil, UserDefaults.standard.string(forKey: "appLockInCaptures") == nil { return false }
        #endif
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    // MARK: - Wiring

    /// Idempotent; called from `OpenWebUIApp.init` so the observers exist before
    /// the first scene connects (the cover is then up before the first frame).
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, _ phase: AppLockPolicy.Phase?) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let scene = note.object as? UIWindowScene else { return }
                MainActor.assumeIsolated { self?.sceneEvent(scene, phase, name) }
            })
        }
        watch(UIScene.willConnectNotification, .inactive)
        watch(UIScene.willEnterForegroundNotification, .inactive)
        watch(UIScene.willDeactivateNotification, .inactive)
        watch(UIScene.didEnterBackgroundNotification, .background)
        watch(UIScene.didActivateNotification, .active)
        watch(UIScene.didDisconnectNotification, nil)
        // A scene can already exist when start() runs late (tests, previews).
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scenePhases[ObjectIdentifier(scene)] = scene.activationState == .foregroundActive ? .active : .inactive
            ensureWindow(for: scene)
        }
        method = AppLockMethod.current()
        pushAggregatePhase()
        applyWindows()
    }

    private func sceneEvent(_ scene: UIWindowScene, _ phase: AppLockPolicy.Phase?, _ name: Notification.Name) {
        let id = ObjectIdentifier(scene)
        guard let phase else {            // disconnected
            scenePhases[id] = nil
            windows[id]?.isHidden = true
            windows[id] = nil
            pushAggregatePhase()
            return
        }
        ensureWindow(for: scene)
        scenePhases[id] = phase
        defer { applyWindows() }     // a cold launch with the lock on shows the cover here
        if name == UIScene.didEnterBackgroundNotification { autoPromptArmed = true }
        if name == UIScene.willDeactivateNotification, policy.isEnabled { dismissKeyboard() }
        pushAggregatePhase()
        if name == UIScene.didActivateNotification {
            method = AppLockMethod.current()    // the person may have enrolled one meanwhile
            if autoPromptArmed, policy.shouldPrompt {
                autoPromptArmed = false
                Task { await unlock() }
            }
        }
    }

    /// With several windows (iPad) the app counts as in the foreground while any
    /// scene is active, and in the background only when all of them are. This
    /// aggregate drives locking and the grace; the COVER is per scene
    /// (`applyWindows`), so a scene that is not active is hidden regardless.
    private func pushAggregatePhase() {
        let phases = scenePhases.values
        let aggregate: AppLockPolicy.Phase =
            phases.contains(.active) ? .active : (phases.contains(.inactive) ? .inactive : .background)
        guard aggregate != policy.phase else { return }
        policy.sceneChanged(to: aggregate, at: Date())
    }

    // MARK: - Unlock

    /// Asks for the biometric / passcode. The button in the lock view and the
    /// automatic prompt both land here; a second call while a sheet is up is a no-op.
    func unlock() async {
        guard policy.isEnabled, policy.isLocked, !policy.isAuthenticating, policy.phase == .active else { return }
        policy.beginAuthentication()
        let result = await Self.authenticate(reason: L("Desbloqueie para ver suas conversas e notas."))
        // Settle first, then end the sheet: the other way round the scene is
        // still `.inactive` for a moment with nothing marked as authenticating,
        // and the cover would blink back over the app that was just opened.
        // `.unavailable` (no passcode any more) turns the lock off inside the
        // policy, and `.failed` leaves its reason for the cover to show; in
        // both cases the button stays usable because `endAuthentication` always
        // runs (finding #19).
        policy.authenticationFinished(result, at: Date())
        policy.endAuthentication()
        if result == .unavailable, !policy.isEnabled {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            turnedOffByUnavailability = true
        }
    }

    /// Turns the lock on. Only after an authentication that just succeeded, so a
    /// device whose passcode cannot be entered is never locked out of its own
    /// chats. Returns the reason it stayed off, if it did.
    func enable() async -> AppLockAuthResult {
        guard !policy.isEnabled else { return .success }
        turnedOffByUnavailability = false
        policy.beginAuthentication()
        let result = await Self.authenticate(reason: L("Confirme para ativar o bloqueio do app."))
        if result == .success {
            // If the scene went to the background while the sheet was up, the
            // policy enables the lock already engaged (finding #21).
            policy.setEnabled(true, authenticatedAt: Date())
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        policy.endAuthentication()      // after setEnabled, for the same reason as in unlock()
        return result
    }

    func disable() {
        guard policy.isEnabled else { return }
        turnedOffByUnavailability = false
        policy.setEnabled(false, authenticatedAt: Date())
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    /// `.deviceOwnerAuthentication`: biometrics, with the device passcode as the
    /// fallback the sheet offers by itself, so a wet finger or a mask is not a
    /// dead end (`...WithBiometrics` would be).
    private static func authenticate(reason: String) async -> AppLockAuthResult {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .systemCancel, .appCancel: return .cancelled
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled: return .unavailable
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: - Windows

    private func ensureWindow(for scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard windows[id] == nil else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level.alert + 1
        w.isHidden = true      // the content is built when it is first needed (applyWindows)
        windows[id] = w
    }

    /// One decision per window, from that scene's OWN phase: on iPad a scene in
    /// the app switcher or Slide Over is covered while another one is active
    /// (finding #20). A scene we have no phase for yet counts as the aggregate.
    private func applyWindows() {
        for (id, w) in windows {
            let show = policy.coverVisible(forScene: scenePhases[id] ?? policy.phase)
            guard w.isHidden == show else { continue }
            if show {
                // A new store each time: the theme and font may have changed
                // since the window was built, and the cover must match them.
                w.rootViewController = UIHostingController(rootView: AppLockRoot(lock: self))
                w.rootViewController?.view.backgroundColor = .clear
                w.rootViewController?.view.accessibilityViewIsModal = true   // VoiceOver stays on the lock
                w.isHidden = false
            } else {
                w.isHidden = true
                w.rootViewController = nil
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Root of the cover window: carries the environment the main window gets from
/// `OpenWebUIApp` (theme, locale, direction), because a separate UIWindow does
/// not inherit it.
private struct AppLockRoot: View {
    @ObservedObject var lock: AppLock
    @ObservedObject private var lang = LanguageManager.shared
    @StateObject private var themes = ThemeStore()

    var body: some View {
        AppLockView(lock: lock)
            // The opaque theme, not `effectiveTheme`: a translucent background
            // over the chat would defeat the cover.
            .environment(\.theme, themes.theme)
            .environment(\.locale, lang.locale)
            .environment(\.layoutDirection, lang.layoutDirection)
            .preferredColorScheme(themes.theme.isDark ? .dark : .light)
            .tint(themes.theme.accent)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The cover: the brand mark alone while the scene is merely inactive (the app
/// switcher, Control Center), plus the unlock button once it is locked.
struct AppLockView: View {
    @ObservedObject var lock: AppLock
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if theme.backdrop { ThemeBackdrop(theme: theme).ignoresSafeArea() }
            VStack(spacing: 18) {
                BrandMark(size: 84)
                if lock.policy.isLocked {
                    Text("Bloqueado")
                        .font(.ody(.title3, weight: .semibold)).foregroundStyle(theme.fg)
                    Text("Desbloqueie para ver suas conversas e notas.")
                        .font(.ody(.subheadline)).foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                    // Why the last attempt did not open the app: without it the
                    // button seems to do nothing (finding #19).
                    if lock.policy.lastFailure == .failed {
                        Text("Não foi possível confirmar sua identidade. Toque em Desbloquear para tentar de novo.")
                            .font(.ody(.footnote)).foregroundStyle(theme.danger)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("appLock.failure")
                    }
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label { Text("Desbloquear") } icon: { Image(systemName: lock.method.symbol) }
                            .font(.ody(.headline))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 28).padding(.vertical, 14)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: Radius.control))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .accessibilityIdentifier("appLock.unlock")
                }
            }
            .padding(.horizontal, 32)
        }
        .accessibilityIdentifier("appLock.cover")
    }
}

/// The Settings section: one toggle, and why it may be off.
struct AppLockSettingsSection: View {
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.theme) private var theme
    @State private var notice: AppLockAuthResult?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { lock.isEnabled }, set: { on in
                if on { Task { notice = await lock.enable() } } else { lock.disable(); notice = nil }
            })) {
                Label { lock.method.settingsTitle.font(.ody(.body)).foregroundStyle(theme.fg) }
                icon: { Image(systemName: lock.method.symbol).foregroundStyle(theme.accent) }
            }
            .tint(theme.accent)
            .accessibilityIdentifier("settings.appLock")
            .listRowBackground(theme.panel)
        } header: {
            Text("PRIVACIDADE").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pede para desbloquear ao abrir o app e ao voltar para ele, e esconde as conversas no seletor de apps.")
                if lock.turnedOffByUnavailability && !lock.isEnabled {
                    Text("O bloqueio foi desativado porque o aparelho não tem mais um código de acesso. Defina um nos Ajustes do aparelho para usá-lo de novo.")
                        .foregroundStyle(theme.danger)
                } else if notice == .unavailable {
                    Text("Para usar o bloqueio, defina um código de acesso nos Ajustes do aparelho.")
                        .foregroundStyle(theme.danger)
                } else if notice == .failed {
                    Text("Não foi possível confirmar sua identidade. O bloqueio continua desativado.")
                        .foregroundStyle(theme.danger)
                }
            }
            .font(.ody(size: 12)).foregroundStyle(theme.secondaryText)
        }
    }
}
#endif
