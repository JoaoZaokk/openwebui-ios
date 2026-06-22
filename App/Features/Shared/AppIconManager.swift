import UIKit

/// Switches the home-screen app icon to match the active theme. iOS shows a
/// system alert on each change (unavoidable) — it lands right after the user
/// picks a theme, which is an intentional action.
enum AppIconManager {
    /// Alternate icon name for a theme, or nil for the primary (Hermes blue).
    /// Every theme family maps to a distinct icon so the home-screen icon always
    /// matches the active skin — the non-brand Odysseus themes share the original
    /// Odysseus sail icon (instead of silently inheriting the Hermes-blue primary).
    static func iconName(for themeID: String) -> String? {
        switch themeID {
        case "claude", "claude_code": return "AppIcon-claude"
        case "gpt", "codex":          return "AppIcon-openai"
        case "gemini":                return "AppIcon-gemini"
        case "openwebui":             return "AppIcon-openwebui"
        case "hermes":                return nil   // primary asset-catalog icon (Hermes blue)
        case "hermes_teal":           return "AppIcon-hermesteal"
        case "hermes_noir":           return "AppIcon-hermesnoir"
        default:                      return "AppIcon-odysseus"  // Midnight, Ocean, …
        }
    }

    @MainActor
    static func apply(themeID: String) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let target = iconName(for: themeID)
        guard app.alternateIconName != target else { return }
        app.setAlternateIconName(target)
    }
}
