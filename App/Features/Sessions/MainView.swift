import SwiftUI
import OpenWebUIKit

/// Main tabbed shell once logged in: Conversas + Notas. (Workspace tab next.)
struct MainView: View {
    let app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            ChatListView(app: app)
                .tabItem { Label("Conversas", systemImage: "bubble.left.and.bubble.right") }
            NotesView(app: app)
                .tabItem { Label("Notas", systemImage: "note.text") }
            ImageGenView(app: app)
                .tabItem { Label("Imagem", systemImage: "photo.artframe") }
            VoiceView(app: app)
                .tabItem { Label("Voz", systemImage: "waveform") }
            WorkspaceView(app: app)
                .tabItem { Label("Workspace", systemImage: "square.grid.2x2") }
        }
        .tint(theme.accent)
    }
}

/// The chat list (Conversas tab).
struct ChatListView: View {
    let app: AppState
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme
    @StateObject private var store: ChatStore
    @State private var path: [ChatRoute] = []
    @State private var showSettings = false
    @State private var showArchived = false
    @State private var search = ""
    @State private var renaming: OWChatSummary?
    @State private var renameText = ""
    @State private var shareItem: ShareableURL?

    init(app: AppState) {
        self.app = app
        _store = StateObject(wrappedValue: app.makeChatStore())
    }

    enum ChatRoute: Hashable {
        case existing(OWChatSummary)
        case new(temporary: Bool)
    }

    private var filtered: [OWChatSummary] {
        guard !search.isEmpty else { return store.chats }
        return store.chats.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                theme.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Open WebUI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { path.append(.new(temporary: false)) } label: {
                            Label("Nova conversa", systemImage: "square.and.pencil")
                        }
                        Button { path.append(.new(temporary: true)) } label: {
                            Label("Conversa temporária", systemImage: "clock.badge.xmark")
                        }
                        Divider()
                        Button { showArchived = true } label: {
                            Label("Arquivadas", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .existing(let c):
                    ChatScreen(app: app, chat: c, onChanged: { Task { await store.load() } })
                case .new(let temp):
                    ChatScreen(app: app, chat: nil, temporary: temp, onChanged: { Task { await store.load() } })
                }
            }
            .task { await store.load() }
            .refreshable { await store.load() }
        }
        .tint(theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app).environmentObject(themes)
        }
        .sheet(isPresented: $showArchived) {
            ArchivedChatsView(app: app).environment(\.theme, theme)
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert("Renomear conversa", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Título", text: $renameText)
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Salvar") {
                if let c = renaming { Task { await store.rename(c, to: renameText) } }
                renaming = nil
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.chats.isEmpty && store.loading {
            ProgressView().tint(theme.accent)
        } else if store.chats.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { chat in
                Button { path.append(.existing(chat)) } label: { row(chat) }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.bg)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await store.delete(chat) } } label: {
                            Label("Apagar", systemImage: "trash")
                        }
                        Button { startRename(chat) } label: {
                            Label("Renomear", systemImage: "pencil")
                        }.tint(theme.accent)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await store.pin(chat) } } label: {
                            Label(LocalizedStringKey(chat.pinned ? "Desafixar" : "Fixar"), systemImage: "pin")
                        }.tint(.orange)
                    }
                    .contextMenu { chatActions(chat) }
            }
            if let err = store.error {
                Text(err).font(.ody(.footnote, design: .monospaced))
                    .foregroundStyle(theme.accent).listRowBackground(theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Buscar conversas")
    }

    private func row(_ chat: OWChatSummary) -> some View {
        HStack(spacing: 10) {
            if chat.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent) }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.ody(.subheadline, design: .monospaced))
                    .foregroundStyle(theme.fg).lineLimit(1)
                if let ts = chat.updatedAt {
                    Text(RelativeDate.string(ts))
                        .font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.secondaryText.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Native Open WebUI chat actions (long-press menu).
    @ViewBuilder private func chatActions(_ chat: OWChatSummary) -> some View {
        Button { Task { await store.pin(chat) } } label: {
            Label(LocalizedStringKey(chat.pinned ? "Desafixar" : "Fixar"), systemImage: chat.pinned ? "pin.slash" : "pin")
        }
        Button { startRename(chat) } label: { Label("Renomear", systemImage: "pencil") }
        Button { Task { await store.clone(chat) } } label: { Label("Clonar", systemImage: "doc.on.doc") }
        Button {
            Task { if let u = await store.shareLink(chat) { shareItem = ShareableURL(url: u) } }
        } label: { Label("Compartilhar", systemImage: "square.and.arrow.up") }
        Button {
            Task { await store.unshare(chat) }
        } label: { Label("Parar de compartilhar", systemImage: "link.badge.minus") }
        Button {
            Task { if let u = await store.export(chat) { shareItem = ShareableURL(url: u) } }
        } label: { Label("Baixar", systemImage: "arrow.down.doc") }
        Button { Task { await store.archive(chat) } } label: { Label("Arquivar", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { Task { await store.delete(chat) } } label: {
            Label("Excluir", systemImage: "trash")
        }
    }

    private func startRename(_ chat: OWChatSummary) {
        renameText = chat.title
        renaming = chat
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            BrandMark(size: 56)
            Text("Nenhuma conversa ainda")
                .font(.ody(.headline, design: .monospaced)).foregroundStyle(theme.fg)
            Button { path.append(.new(temporary: false)) } label: {
                Label("Nova conversa", systemImage: "square.and.pencil")
                    .font(.ody(.subheadline, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.accent, in: Capsule()).foregroundStyle(.white)
            }
        }
    }
}

/// Browse archived chats like normal conversations — tap to open and read the
/// full thread, or swipe to restore (OWUI's archive is a toggle) / delete.
/// Presented as a sheet from the chat list's menu.
struct ArchivedChatsView: View {
    let app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [OWChatSummary] = []
    @State private var loading = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if loading {
                    ProgressView().tint(theme.accent)
                } else if chats.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 40)).foregroundStyle(theme.secondaryText)
                        Text("Nenhuma conversa arquivada.")
                            .font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    }
                } else {
                    List {
                        ForEach(chats) { c in
                            NavigationLink {
                                ChatScreen(app: app, chat: c, onChanged: {}).environment(\.theme, theme)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title.isEmpty ? L("Sem título") : c.title)
                                        .font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg).lineLimit(1)
                                    if let t = c.updatedAt ?? c.createdAt {
                                        Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: t)))
                                            .font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
                                    }
                                }
                            }
                            .listRowBackground(theme.panel)
                            .swipeActions {
                                Button(role: .destructive) { remove(c, delete: true) } label: {
                                    Label("Apagar", systemImage: "trash")
                                }
                                Button { remove(c, delete: false) } label: {
                                    Label("Restaurar", systemImage: "tray.and.arrow.up")
                                }.tint(theme.accent)
                            }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Conversas arquivadas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { dismiss() }.foregroundStyle(theme.accent)
                }
            }
            .task {
                loading = true
                chats = (try? await app.client.archivedChats()) ?? []
                loading = false
            }
        }
        .tint(theme.accent)
    }

    /// Restore (unarchive, via the toggle endpoint) or delete, then drop the row.
    private func remove(_ c: OWChatSummary, delete: Bool) {
        chats.removeAll { $0.id == c.id }
        Task {
            if delete { try? await app.client.deleteChat(c.id) }
            else { try? await app.client.archiveChat(c.id) }
        }
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges the platform share UI for share links / file export.
#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
/// macOS: simple share via NSSharingServicePicker anchored to a plain view.
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Text("Compartilhar").font(.headline)
            if let url = items.first as? URL {
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
                Button("Copiar link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    dismiss()
                }
            }
            Button("Fechar") { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
#endif

/// Shared pt-BR relative-time formatter.
enum RelativeDate {
    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated
        return f
    }()
    static func string(_ epochSeconds: Double) -> String {
        fmt.localizedString(for: Date(timeIntervalSince1970: epochSeconds), relativeTo: Date())
    }
}
