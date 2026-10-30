#if os(iOS)
import UIKit
#endif

/// Switches the home-screen app icon to match the active theme. iOS shows a
/// system alert on each change (unavoidable) — it lands right after the user
/// picks a theme, which is an intentional action.
enum AppIconManager {
    /// Alternate icon name for a theme, or nil for the primary (the black
    /// Open WebUI "OI"). Hermes has no blue icon of its own any more and shares it.
    /// Every theme family maps to a distinct icon so the home-screen icon always
    /// matches the active skin — the non-brand Odysseus themes share the original
    /// Odysseus sail icon (instead of silently inheriting the Hermes-blue primary).
    static func iconName(for themeID: String) -> String? {
        switch themeID {
        case "claude", "claude_code": return "AppIcon-claude"
        case "gpt", "codex":          return "AppIcon-openai"
        case "gemini":                return "AppIcon-gemini"
        case "openwebui", "hermes":   return nil   // primary asset-catalog icon (OI)
        case "hermes_teal":           return "AppIcon-hermesteal"
        case "hermes_noir":           return "AppIcon-hermesnoir"
        default:                      return "AppIcon-odysseus"  // Midnight, Ocean, …
        }
    }

    @MainActor
    static func apply(themeID: String) {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let target = iconName(for: themeID)
        guard app.alternateIconName != target else { return }
        // Open WebUI used to be an alternate with the same picture as the
        // primary; moving those users back would only cost them the alert.
        if target == nil, app.alternateIconName == "AppIcon-openwebui" { return }
        app.setAlternateIconName(target)
        #endif
    }
}
