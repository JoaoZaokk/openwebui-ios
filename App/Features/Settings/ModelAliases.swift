import SwiftUI
import OpenWebUIKit

/// User-set display names for models, so a picker doesn't have to read
/// `gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL`. Stored locally (UserDefaults) rather
/// than on the server: the model list is read-only for non-admin accounts, and
/// a nickname is a per-device preference, not server state.
@MainActor
final class ModelAliases: ObservableObject {
    static let shared = ModelAliases()

    private static let key = "models.aliases"

    @Published private(set) var map: [String: String]

    private init() {
        map = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Sets (or clears, when `name` is blank) the nickname for `id`.
    func set(_ name: String, for id: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: id) } else { map[id] = trimmed }
        UserDefaults.standard.set(map, forKey: Self.key)
    }

    func alias(for id: String) -> String? { map[id] }

    /// What the UI should show for a model: the nickname if the user set one,
    /// the server's short name otherwise.
    func display(_ model: OWModel) -> String { map[model.id] ?? model.shortName }

    /// Same, when only the id is at hand (chat header before the model list
    /// loads, persisted `message.model`, …).
    func display(id: String, fallback: String? = nil) -> String {
        map[id] ?? fallback ?? id
    }
}

/// Rename every model the server offers. One row per model: the raw id stays
/// visible underneath so a nickname can never make a model unidentifiable.
struct ModelNamesView: View {
    let models: [OWModel]
    @EnvironmentObject private var aliases: ModelAliases
    @Environment(\.theme) private var theme
    @State private var drafts: [String: String] = [:]

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            List {
                Section {
                    ForEach(models) { m in row(m) }
                } footer: {
                    Text("Só muda o nome exibido neste aparelho — o modelo enviado ao servidor continua o mesmo. Deixe em branco para voltar ao nome original.")
                        .font(.ody(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Nomes dos modelos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { drafts = aliases.map }
    }

    private func row(_ m: OWModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(m.shortName, text: binding(for: m.id))
                .font(.ody(.body, design: .monospaced))
                .foregroundStyle(theme.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text(verbatim: m.id)
                .font(.ody(size: 10, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 4)
        .listRowBackground(theme.panel)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" },
                set: { drafts[id] = $0; aliases.set($0, for: id) })
    }
}
