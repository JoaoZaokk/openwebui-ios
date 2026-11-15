import Foundation

/// When the app lets the model see what the user keeps on the server: their
/// Personalization > Memory, and their Notes. One place, so chat and voice cannot
/// disagree and the rules can be tested without a screen.
///
/// Every input has to say yes:
///
/// - the server has the feature on (`/api/config` `features.enable_memories` /
///   `enable_notes` — in the signed-in answer only, so unknown is "no");
/// - the user may use it (`features.memories` / `features.notes` from
///   `GET /api/v1/auths/`; an admin always may). The server re-checks memory
///   itself because `features` comes from the client (middleware.py:2366), and
///   answers 401 to `/api/v1/notes` without the permission — and the client
///   treats a 401 as a dead session, so the app does not ask;
/// - the user left the app's own switch on (Ajustes › Conversa).
public enum OWPersonalContext {

    /// Send `features.memory: true`.
    public static func sendsMemory(config: OWServerConfig?, user: OWUser?, setting: Bool) -> Bool {
        setting && (config?.memoriesAvailable ?? false) && (user?.mayUseMemories ?? false)
    }

    /// Declare and run the notes tools.
    ///
    /// Besides the three above, two things on the same request rule it out. A
    /// request with its own `tools` key makes the server skip its tool
    /// resolution altogether (middleware.py ~2656), so declaring ours next to
    /// workspace `tool_ids`, or next to the server's own web search
    /// (`features.web_search`, which runs through the same resolution), would
    /// silently turn those off. The user's explicit choice for that message wins;
    /// the notes tools are the ones that wait.
    public static func offersNotes(config: OWServerConfig?, user: OWUser?, setting: Bool,
                                   toolIDs: [String], serverWebSearch: Bool) -> Bool {
        setting && (config?.notesAvailable ?? false) && (user?.mayUseNotes ?? false)
            && toolIDs.isEmpty && !serverWebSearch
    }

    /// Ajustes › Conversa › "Usar memória" / "Consultar notas": on by default.
    public static let memorySettingKey = "chat.memory"
    public static let notesSettingKey = "chat.notes"

    public static func setting(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
