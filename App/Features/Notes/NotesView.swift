import SwiftUI
import OpenWebUIKit

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [OWNote] = []
    @Published var loading = false
    @Published var error: String?

    private let client: OpenWebUIClient
    init(client: OpenWebUIClient) { self.client = client }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            notes = try await client.notes().sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ note: OWNote) async {
        do {
            try await client.deleteNote(note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct NotesView: View {
    let app: AppState
    @Environment(\.theme) private var theme
    @StateObject private var store: NotesStore
    @State private var editing: NoteEdit?

    init(app: AppState) {
        self.app = app
        _store = StateObject(wrappedValue: NotesStore(client: app.client))
    }

    /// Identifiable wrapper for the editor sheet (nil note = new).
    struct NoteEdit: Identifiable { let id = UUID(); var note: OWNote? }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if store.notes.isEmpty && store.loading {
                    ProgressView().tint(theme.accent)
                } else if store.notes.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Notas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = NoteEdit(note: nil) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(Text("Nova nota"))
                }
            }
            .task { await store.load() }
            .refreshable { await store.load() }
            .sheet(item: $editing, onDismiss: { Task { await store.load() } }) { e in
                NoteEditorView(client: app.client, note: e.note)
            }
        }
        .tint(theme.accent)
    }

    private var list: some View {
        List {
            ForEach(store.notes) { note in
                Button { editing = NoteEdit(note: note) } label: { row(note) }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.bg)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await store.delete(note) } } label: {
                            Label("Apagar", systemImage: "trash")
                        }
                    }
            }
            if let err = store.error {
                Text(err).font(.ody(.footnote, design: .monospaced))
                    .foregroundStyle(theme.danger).listRowBackground(theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ note: OWNote) -> some View {
        HStack(spacing: 10) {
            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent) }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.ody(.subheadline, design: .monospaced))
                    .foregroundStyle(theme.fg).lineLimit(1)
                let preview = note.markdown.replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview).font(.ody(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            Spacer()
            if let ts = note.updatedAt {
                Text(RelativeDate.string(ts)).font(.ody(size: 9, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text").font(.ody(size: 44)).foregroundStyle(theme.accent)
            Text("Nenhuma nota ainda")
                .font(.ody(.headline, design: .monospaced)).foregroundStyle(theme.fg)
            Button { editing = NoteEdit(note: nil) } label: {
                Label("Nova nota", systemImage: "square.and.pencil")
                    .font(.ody(.subheadline, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.accent, in: Capsule()).foregroundStyle(theme.onAccent)
            }
        }
    }
}

/// Title + markdown editor. Creates a new note or updates an existing one.
struct NoteEditorView: View {
    let client: OpenWebUIClient
    let note: OWNote?
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var markdown: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    init(client: OpenWebUIClient, note: OWNote?) {
        self.client = client
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _markdown = State(initialValue: note?.markdown ?? "")
    }

    private var canSave: Bool {
        !(title.trimmingCharacters(in: .whitespaces).isEmpty && markdown.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    TextField("Título", text: $title)
                        .font(.ody(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().overlay(theme.border)
                    TextEditor(text: $markdown)
                        .font(.ody(.body, design: .monospaced))
                        .foregroundStyle(theme.fg)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .focused($bodyFocused)
                        .overlay(alignment: .topLeading) {
                            if markdown.isEmpty {
                                Text("Escreva em markdown…")
                                    .font(.ody(.body, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                    .padding(.horizontal, 17).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    if let error {
                        Text(error).font(.ody(size: 11, design: .monospaced))
                            .foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(note == nil ? "Nova nota" : "Editar nota"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(saving ? "Salvando…" : "Salvar")) { Task { await save() } }
                        .disabled(!canSave || saving)
                }
            }
            .background(theme.bg)
        }
        .tint(theme.accent)
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(markdown.prefix(40)) : title
        do {
            if let note {
                try await client.updateNote(id: note.id, title: finalTitle, markdown: markdown)
            } else {
                try await client.createNote(title: finalTitle, markdown: markdown)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
