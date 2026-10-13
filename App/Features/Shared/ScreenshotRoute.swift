#if DEBUG
import Foundation
import OpenWebUIKit

/// Opens one screen at launch, for App Store captures: `-screenshotRoute <route>`
/// on the launch command line (it lands in `UserDefaults`). Debug builds only —
/// nothing here ships.
///
/// Routes: `list`, `chat:<chat id>`, `voice:<chat id>` (the chat, with the voice
/// mode over it), `ask:<question>` (a new chat that sends the question by
/// itself — the way accented text gets in), `notes`, `note:<note id>`,
/// `image:<prompt>` (generates it), `voicetab`, `workspace`, `settings`.
///
/// With the local stub: `-openwebui.baseURL http://127.0.0.1:8778`,
/// `-screenshotToken <any>` (signed in without the login screen) and
/// `-screenshotHost <name>` (the server name shown instead of 127.0.0.1).
enum ScreenshotRoute {
    static var raw: String? { string("screenshotRoute") }

    /// The route's argument when it starts with `prefix:`.
    static func value(_ prefix: String) -> String? {
        guard let r = raw, r.hasPrefix(prefix + ":") else { return nil }
        return String(r.dropFirst(prefix.count + 1))
    }

    static func matches(_ name: String) -> Bool { raw == name }

    /// The tab a route opens on: Conversas 0, Notas 1, Imagem 2, Voz 3, Workspace 4.
    static var tab: Int {
        guard let r = raw else { return 0 }
        if r == "notes" || r.hasPrefix("note:") { return 1 }
        if r.hasPrefix("image:") { return 2 }
        if r == "voicetab" { return 3 }
        if r == "workspace" { return 4 }
        return 0
    }

    /// `-screenshotHost <name>`: the server name shown in the UI.
    static var hostLabel: String? { string("screenshotHost") }

    /// `-screenshotToken <token>`: saved before the client reads the Keychain, so
    /// a capture run opens signed in to the stub.
    static func primeToken(_ keychain: OWKeychainStore) {
        if let t = string("screenshotToken") { keychain.save(token: t) }
    }

    /// One-shot actions (sending a question, generating an image) must not run
    /// again when SwiftUI rebuilds the view that triggers them.
    @MainActor private static var done: Set<String> = []
    @MainActor static func once(_ key: String) -> Bool { done.insert(key).inserted }

    private static func string(_ key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key)
        return (v?.isEmpty ?? true) ? nil : v
    }
}
#endif
