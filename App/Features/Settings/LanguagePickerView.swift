import SwiftUI
import OpenWebUIKit

/// Language chooser. "Automatic" follows the device language (auto-detected on
/// first launch); the explicit rows override it at runtime. Switching is live —
/// `LanguageManager` flips `\.locale` + the `L(_:)` bundle and the root view's
/// `.id` rebuilds the tree.
struct LanguagePickerView: View {
    @EnvironmentObject private var lang: LanguageManager
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if theme.backdrop { ThemeBackdrop(theme: theme) }
            List {
                Section {
                    row(
                        leading: "🌐",
                        title: Text("Automático (idioma do aparelho)"),
                        subtitle: LanguageManager.deviceLanguage().endonym,
                        selected: lang.isAutomatic
                    ) { lang.set(nil) }
                } header: {
                    header("IDIOMA")
                }

                Section {
                    ForEach(AppLanguage.allCases) { l in
                        row(
                            leading: l.flag,
                            title: Text(verbatim: l.endonym),
                            subtitle: nil,
                            selected: !lang.isAutomatic && lang.current == l
                        ) { lang.set(l) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Idioma")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.accent)
    }

    @ViewBuilder
    private func row(leading: String, title: Text, subtitle: String?, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(verbatim: leading).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 1) {
                    title.font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.ody(.caption2, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                }
            }
        }
        .listRowBackground(theme.panel)
    }

    private func header(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.ody(size: 11, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
    }
}
