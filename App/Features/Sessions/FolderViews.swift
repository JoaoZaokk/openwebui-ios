import SwiftUI
import OpenWebUIKit

/// Name and instruction of one folder. The instruction is read when the sheet
/// opens (the folder list does not carry it) and saved together with the name.
struct FolderEditorView: View {
    let folder: OWFolder
    @ObservedObject var store: ChatStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                Form {
                    Section {
                        TextField("Nome da pasta", text: $name)
                            .font(.ody(.body)).foregroundStyle(theme.fg)
                            .accessibilityIdentifier("folder.name")
                            .listRowBackground(theme.panel)
                    }
                    Section {
                        TextEditor(text: $instructions)
                            .font(.ody(.body)).foregroundStyle(theme.fg)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .accessibilityIdentifier("folder.instructions")
                            .listRowBackground(theme.panel)
                    } header: {
                        Text("Instruções da pasta").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                    } footer: {
                        Text("Toda conversa desta pasta começa com estas instruções.")
                            .font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Pasta")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        Task {
                            await store.updateFolder(folder.id, name: name, systemPrompt: instructions)
                            dismiss()
                        }
                    }
                    .disabled(!loaded || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("folder.save")
                }
            }
        }
        .tint(theme.accent)
        .task {
            name = folder.name
            if let d = await store.folderDetail(folder.id) {
                name = d.name
                instructions = d.systemPrompt ?? ""
            }
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

private extension View {
    /// `navigationBarTitleDisplayMode` exists on iOS only; the Mac target builds
    /// this file too.
    @ViewBuilder func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension ChatStore {
    /// Folders in the order they read: each parent followed by its children, with
    /// the depth the list indents by. A folder whose parent is not in the list (a
    /// parent the account cannot see) is drawn at the top level.
    var folderRows: [(folder: OWFolder, depth: Int)] {
        let ids = Set(folders.map(\.id))
        var out: [(OWFolder, Int)] = []
        func walk(_ parent: String?, _ depth: Int, _ seen: Set<String>) {
            for f in folders where (f.parentID.flatMap { ids.contains($0) ? $0 : nil }) == parent && !seen.contains(f.id) {
                out.append((f, depth))
                walk(f.id, depth + 1, seen.union([f.id]))
            }
        }
        walk(nil, 0, [])
        return out.map { (folder: $0.0, depth: $0.1) }
    }
}
