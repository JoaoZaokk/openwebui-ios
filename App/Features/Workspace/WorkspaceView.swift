import SwiftUI
import OpenWebUIKit

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var models: [OWModel] = []
    @Published var knowledge: [OWNamedItem] = []
    @Published var prompts: [OWNamedItem] = []
    @Published var tools: [OWNamedItem] = []
    @Published var functions: [OWNamedItem] = []
    @Published var loading = false
    @Published var error: String?

    private let client: OpenWebUIClient
    init(client: OpenWebUIClient) { self.client = client }

    func load() async {
        loading = true
        defer { loading = false }
        error = nil
        models = await keep(models) { try await self.client.models() }
        knowledge = await keep(knowledge) { try await self.client.knowledgeBases() }
        prompts = await keep(prompts) { try await self.client.prompts() }
        tools = await keep(tools) { try await self.client.tools() }
        functions = await keep(functions) { try await self.client.functions() }
    }

    /// Runs one section's fetch, keeping what is already on screen if it fails and
    /// recording the first reason. Five bare `try?`s used to turn a dropped
    /// connection into five sections all reading "Vazio (0)" — the screen claimed
    /// the server had nothing rather than admitting it never asked successfully.
    private func keep<T>(_ current: [T], _ fetch: () async throws -> [T]) async -> [T] {
        do { return try await fetch() }
        catch is CancellationError { return current }
        catch {
            if self.error == nil {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return current
        }
    }
}

/// Read-only Workspace: Models, Knowledge, Prompts, Tools, Functions.
/// (Heavy admin config is intentionally out of scope.)
struct WorkspaceView: View {
    let app: AppState
    @Environment(\.theme) private var theme
    @StateObject private var store: WorkspaceStore

    init(app: AppState) {
        self.app = app
        _store = StateObject(wrappedValue: WorkspaceStore(client: app.client))
    }

    struct Row: Identifiable { let id = UUID(); let name: String; let sub: String? }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                List {
                    sec("Modelos", "cpu", store.models.map { Row(name: $0.shortName, sub: $0.ownedBy) })
                    sec("Conhecimento", "books.vertical", store.knowledge.map { Row(name: $0.name, sub: $0.description) })
                    sec("Prompts", "text.quote", store.prompts.map { Row(name: $0.name, sub: $0.description) })
                    sec("Tools", "wrench.and.screwdriver", store.tools.map { Row(name: $0.name, sub: $0.description) })
                    sec("Functions", "function", store.functions.map { Row(name: $0.name, sub: $0.description) })
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                if store.loading && store.models.isEmpty { ProgressView().tint(theme.accent) }
            }
            .errorBanner(store.error) { store.error = nil }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.load() }
            .refreshable { await store.load() }
        }
        .tint(theme.accent)
    }

    @ViewBuilder
    private func sec(_ title: String, _ icon: String, _ rows: [Row]) -> some View {
        Section {
            if rows.isEmpty {
                Text("Vazio")
                    .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    .listRowBackground(theme.panel.opacity(0.35))
            } else {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                        if let s = r.sub, !s.isEmpty {
                            Text(s).font(.ody(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText).lineLimit(2)
                        }
                    }
                    .listRowBackground(theme.panel.opacity(0.35))
                }
            }
        } header: {
            Label("\(title) (\(rows.count))", systemImage: icon)
                .font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
        }
    }
}
