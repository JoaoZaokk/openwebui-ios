import Foundation

/// When the app lock engages and what must be hidden, as a pure state machine.
///
/// Added in 1.13 after a request to put Face ID / Touch ID in front of the app:
/// a local model's chats and notes can hold the most personal text on the
/// phone. The LocalAuthentication prompt, the cover window and the scene
/// notifications are glue in `App/`; every decision lives here so it can be
/// pinned by a test, because none of it can be tried without a device.
///
/// Rules, each one a mistake someone would otherwise make:
/// - **Lock on the way out, not on the way back.** Entering `.background` locks
///   at once (with the default grace of 0), so the state is already right if the
///   process is killed or the snapshot is taken late.
/// - **`.inactive` never locks.** Control Center, the notification shade, an
///   incoming call banner and the Face ID sheet itself all pass through
///   `.inactive`. They hide the content (`coverVisible`) but do not ask for a
///   second authentication.
/// - **The cover is separate from the lock.** The app switcher snapshot is taken
///   when the scene stops being active, so the cover goes up on `.inactive` as
///   well, even though nothing is locked.
/// - **Grace is time away, measured per trip,** from entering `.background` to
///   becoming `.active` again; a clock that went backwards locks.
public struct AppLockPolicy: Equatable, Sendable {

    /// Mirror of SwiftUI's `ScenePhase` / the UIKit scene notifications, so the
    /// kit does not depend on either.
    public enum Phase: Equatable, Sendable { case active, inactive, background }

    /// How one LocalAuthentication round ended. Mirrored here so what each
    /// ending means for the lock is decided (and tested) in the kit.
    public enum AuthOutcome: Equatable, Sendable {
        case success
        /// The person dismissed the sheet, or the system did (app switched away).
        case cancelled
        /// Nothing to authenticate with: no passcode set, biometrics gone.
        case unavailable
        case failed
    }

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var phase: Phase
    /// Seconds away that are forgiven. 0 (the default) means every trip to the
    /// background locks.
    public let gracePeriod: TimeInterval
    /// When the current absence started; `nil` while in the foreground.
    public private(set) var backgroundedAt: Date?
    public private(set) var lastUnlock: Date?
    /// A system authentication sheet is up (the unlock itself, or the one that
    /// confirms turning the setting on). The scene goes `.inactive` under it.
    public private(set) var isAuthenticating = false
    /// Why the last unlock attempt did not open the app, for the cover to show
    /// (review finding #19: a button that does nothing and says nothing). Only
    /// `.failed`; a cancel is the person's own choice and needs no explanation.
    public private(set) var lastFailure: AuthOutcome?

    /// - Parameter phase: where the scene is when the policy is created. A cold
    ///   launch begins `.inactive`, and the lock starts engaged when enabled.
    public init(enabled: Bool, gracePeriod: TimeInterval = 0, phase: Phase = .inactive) {
        self.isEnabled = enabled
        self.isLocked = enabled
        self.gracePeriod = max(0, gracePeriod)
        self.phase = phase
    }

    // MARK: - Events

    public mutating func sceneChanged(to new: Phase, at now: Date) {
        phase = new
        guard isEnabled else { backgroundedAt = nil; return }
        switch new {
        case .background:
            if backgroundedAt == nil { backgroundedAt = now }
            if gracePeriod == 0 { isLocked = true }
        case .inactive:
            break
        case .active:
            if let away = backgroundedAt {
                let elapsed = now.timeIntervalSince(away)
                if elapsed < 0 || elapsed >= gracePeriod { isLocked = true }
            }
            backgroundedAt = nil
        }
    }

    /// The authentication succeeded. Ignored when the app has meanwhile left for
    /// the background: a success callback that loses the race with the scene
    /// must not leave the app open behind the person's back.
    public mutating func didUnlock(at now: Date) {
        guard isEnabled, phase != .background else { return }
        isLocked = false
        lastUnlock = now
    }

    /// The setting changed. Turning it on is only done after an authentication
    /// that just succeeded, so the session that enabled it stays open (unless
    /// the app is already in the background, see below) and the lock guards
    /// every later return. Turning it off opens whatever was locked.
    public mutating func setEnabled(_ enabled: Bool, authenticatedAt now: Date) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        isLocked = false
        backgroundedAt = nil
        lastUnlock = enabled ? now : nil
        lastFailure = nil
        // The confirmation sheet can lose the race with the scene: the success
        // arrives after the app went to the background. While the lock was off
        // that trip recorded nothing and the snapshot was uncovered, so the
        // session must not be left open behind the person's back; start the
        // absence now so the next return asks (review finding #21).
        if enabled, phase == .background {
            isLocked = true
            backgroundedAt = now
        }
    }

    /// Settles an unlock attempt, `.success` included.
    ///
    /// `.unavailable` turns the lock off: with no passcode the cover could never
    /// be opened again, and the switch that turns the lock off is in Settings,
    /// behind that same cover. A lock nobody can open is not a lock, it is a
    /// reason to delete the app (review finding #19). The caller persists the
    /// setting when `isEnabled` went from true to false here.
    public mutating func authenticationFinished(_ outcome: AuthOutcome, at now: Date) {
        switch outcome {
        case .success:
            lastFailure = nil
            didUnlock(at: now)
        case .cancelled:
            lastFailure = nil
        case .failed:
            lastFailure = .failed
        case .unavailable:
            if isEnabled { setEnabled(false, authenticatedAt: now) }
        }
    }

    public mutating func beginAuthentication() {
        isAuthenticating = true
        lastFailure = nil
    }
    public mutating func endAuthentication() { isAuthenticating = false }

    // MARK: - Derived

    /// The full-screen cover must be up: locked, or the scene is not active (so
    /// the app switcher snapshot is blank). Not while a system sheet is the
    /// reason the scene is inactive and nothing is locked — Settings would blink.
    public var coverVisible: Bool { coverVisible(forScene: phase) }

    /// The same rule for one scene, given that scene's OWN phase. `phase` is the
    /// aggregate (active while any scene is), which is right for locking but
    /// wrong for covering: on iPad scene B goes to the app switcher or Slide
    /// Over while scene A stays active, and B's snapshot must be blank too
    /// (review finding #20).
    public func coverVisible(forScene scenePhase: Phase) -> Bool {
        guard isEnabled else { return false }
        return isLocked || (scenePhase != .active && !isAuthenticating)
    }

    /// Present the system prompt now: locked, in the foreground, none up yet.
    public var shouldPrompt: Bool {
        isEnabled && isLocked && phase == .active && !isAuthenticating
    }
}
