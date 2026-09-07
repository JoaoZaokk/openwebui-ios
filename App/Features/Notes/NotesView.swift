import SwiftUI
import OpenWebUIKit

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [OWNote] = []
    @Published var loading = false
    @Published var error: String?
    /// True once a load has answered; "no notes" is only a fact after that.
    @Published private(set) var loaded = false

    private let client: OpenWebUIClient
    init(client: OpenWebUIClient) { self.client = client }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            notes = try await client.notes().sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = OWFailure.msg(error)
        }
    }

    func delete(_ note: OWNote) async {
        do {
            try await client.deleteNote(note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            self.error = OWFailure.msg(error)
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
                VStack(spacing: 0) {
                    if !store.notes.isEmpty {
                        list
                    } else if store.loading {
                        ProgressView().tint(theme.accent)
                    } else if store.loaded {
                        emptyState
                    } else {
                        // Failed, nothing to show: the banner says why. Not the
                        // empty state — that one invites a "Nova nota" over notes
                        // that may well exist.
                        ScrollView { Color.clear.frame(height: 1) }
                    }
                }
                .errorBanner(store.error) { store.error = nil }
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ note: OWNote) -> some View {
        HStack(spacing: 10) {
            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent) }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.ody(.subheadline))
                    .foregroundStyle(theme.fg).lineLimit(1)
                let preview = note.markdown.replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview).font(.ody(size: 11))
                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            Spacer()
            if let ts = note.updatedAt {
                Text(RelativeDate.string(ts)).font(.ody(size: 9))
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        // Inside a ScrollView so `.refreshable` has a gesture here too. As a bare
        // VStack this branch was a dead end: the load had already failed, the
        // `.task` does not re-fire on tab switch, and pull-to-refresh needs
        // something scrollable — the only way back was relaunching the app.
        ScrollView { emptyStateBody.frame(maxWidth: .infinity).padding(.top, 80) }
    }

    private var emptyStateBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text").font(.ody(size: 44)).foregroundStyle(theme.accent)
            Text("Nenhuma nota ainda")
                .font(.ody(.headline)).foregroundStyle(theme.fg)
            Button { editing = NoteEdit(note: nil) } label: {
                Label("Nova nota", systemImage: "square.and.pencil")
                    .font(.ody(.subheadline))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.accent, in: Capsule()).foregroundStyle(theme.onAccent)
            }
        }
    }
}

/// Title + markdown editor. Creates a new note or updates an existing one.
///
/// The note the list hands over is a **preview**, not the note: `GET
/// /api/v1/notes/` runs every entry through `_truncate_note_data(data,
/// max_length=1000)` (backend routers/notes.py:42). The update route then
/// shallow-merges the incoming `data` over the stored one —
/// `note.data = {**(note.data or {}), **(form_data['data'] or {})}`
/// (models/notes.py:354) — so `content` is replaced whole. Seeding the editor
/// from the list and saving it back therefore wrote 1000 characters over the
/// real note and dropped everything after them: any note longer than that was
/// destroyed by being opened and saved.
///
/// So an existing note is fetched by id first, and **Salvar stays disabled until
/// that fetch succeeds**. Without the gate the fix would be worse than the bug —
/// an empty editor that saves is how you lose the whole note instead of its tail.
struct NoteEditorView: View {
    let client: OpenWebUIClient
    let note: OWNote?
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var markdown = ""
    /// The note as `GET /api/v1/notes/{id}` returns it: the whole body, and the
    /// `access_grants` the list strips. This — never the list's copy — is what
    /// goes to `updateNote`, which hands those grants straight back so saving
    /// does not un-share the note. Nil until the fetch lands; a new note never
    /// has one, which is also what tells the two apart at save time.
    @State private var full: OWNote?
    @State private var fetching: Bool
    @State private var saving = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    init(client: OpenWebUIClient, note: OWNote?) {
        self.client = client
        self.note = note
        // Only the title is safe to carry over from the list; the body is cut.
        _title = State(initialValue: note?.title ?? "")
        _fetching = State(initialValue: note != nil)
    }

    /// A new note is ready at once; an existing one only once its whole body has
    /// arrived. Nothing may be typed or saved before that.
    private var ready: Bool { note == nil || full != nil }

    private var canSave: Bool {
        ready && !(title.trimmingCharacters(in: .whitespaces).isEmpty
                   && markdown.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if ready {
                        fields
                    } else {
                        // Fetching, or the fetch failed — and then there is
                        // nothing safe to show, only the error line below.
                        Spacer()
                        if fetching { ProgressView().tint(theme.accent) }
                        Spacer()
                    }
                    if let error {
                        Text(error).font(.ody(size: 11))
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
            .task { await fetch() }
            .background(theme.bg)
        }
        .tint(theme.accent)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            TextField("Título", text: $title)
                .font(.ody(.title3).weight(.semibold))
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(theme.border)
            TextEditor(text: $markdown)
                .font(.ody(.body))
                .foregroundStyle(theme.fg)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .focused($bodyFocused)
                .overlay(alignment: .topLeading) {
                    if markdown.isEmpty {
                        Text("Escreva em markdown…")
                            .font(.ody(.body))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 17).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// Reads the note whole. A new note has nothing to read.
    private func fetch() async {
        guard let note else { return }
        fetching = true
        defer { fetching = false }
        do {
            let whole = try await client.note(note.id)
            title = whole.title
            markdown = whole.markdown
            full = whole
            error = nil
        } catch is CancellationError {
            // The sheet was closed mid-fetch. Everything goes through `send()`,
            // which normalizes a cancelled request to this.
        } catch {
            self.error = OWFailure.msg(error)
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true; error = nil
        defer { saving = false }
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(markdown.prefix(40)) : title
        do {
            if let full {
                try await client.updateNote(full, title: finalTitle, markdown: markdown)
            } else {
                try await client.createNote(title: finalTitle, markdown: markdown)
            }
            dismiss()
        } catch {
            self.error = OWFailure.msg(error)
        }
    }
}
