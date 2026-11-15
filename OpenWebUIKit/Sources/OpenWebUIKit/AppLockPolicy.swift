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
    /// that just succeeded, so the session that enabled it stays open and the
    /// lock guards every later return. Turning it off opens whatever was locked.
    public mutating func setEnabled(_ enabled: Bool, authenticatedAt now: Date) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        isLocked = false
        backgroundedAt = nil
        lastUnlock = enabled ? now : nil
    }

    public mutating func beginAuthentication() { isAuthenticating = true }
    public mutating func endAuthentication() { isAuthenticating = false }

    // MARK: - Derived

    /// The full-screen cover must be up: locked, or the scene is not active (so
    /// the app switcher snapshot is blank). Not while a system sheet is the
    /// reason the scene is inactive and nothing is locked — Settings would blink.
    public var coverVisible: Bool {
        guard isEnabled else { return false }
        return isLocked || (phase != .active && !isAuthenticating)
    }

    /// Present the system prompt now: locked, in the foreground, none up yet.
    public var shouldPrompt: Bool {
        isEnabled && isLocked && phase == .active && !isAuthenticating
    }
}
