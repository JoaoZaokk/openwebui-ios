import SwiftUI
import QuickLook
import PhotosUI
import UniformTypeIdentifiers
import OpenWebUIKit

/// Downloads a terminal file and shows it in Quick Look (which also shares
/// it). Shared by the file browser and the chat's `display_file`.
@MainActor
final class TerminalFileOpener: ObservableObject {
    @Published var previewURL: URL?
    @Published var busyPath: String?
    @Published var error: String?

    func open(_ path: String, isDirectory: Bool = false, terminal: String, session: String?,
              client: OpenWebUIClient) {
        guard busyPath == nil else { return }
        busyPath = path
        Task {
            defer { busyPath = nil }
            do {
                let ext = (path as NSString).pathExtension.lowercased()
                let office = ["docx", "pptx"].contains(ext)
                previewURL = try await client.downloadTerminalFile(terminal, path: path, isDirectory: isDirectory,
                                                                   preview: office, session: session)
            } catch is CancellationError {
            } catch {
                self.error = OWFailure.msg(error)
            }
        }
    }
}

/// A terminal's files: browse, open, upload, make folders, rename, delete.
struct TerminalFilesView: View {
    let client: OpenWebUIClient
    let terminal: OWTerminalServer
    let session: String?
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var opener = TerminalFileOpener()

    @State private var place: OWTerminalPlace?
    @State private var directory: String?
    @State private var listing: OWTerminalListing?
    @State private var loading = false
    @State private var error: String?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var renaming: OWTerminalEntry?
    @State private var newName = ""
    @State private var deleting: OWTerminalEntry?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var uploading = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: title))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .errorBanner(error ?? opener.error) { error = nil; opener.error = nil }
        }
        .tint(theme.accent)
        .task { await start() }
        .quickLookPreview($opener.previewURL)
        .alert("Nova pasta", isPresented: $newFolder) {
            TextField("Nome", text: $folderName)
            Button("Criar") { let n = folderName; folderName = ""; Task { await makeFolder(n) } }
            Button("Cancelar", role: .cancel) { folderName = "" }
        }
        .alert("Renomear", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") {
                let e = renaming; let n = newName; renaming = nil
                if let e { Task { await rename(e, to: n) } }
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { L("Apagar %@?", $0.name) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                let e = deleting; deleting = nil
                if let e { Task { await delete(e) } }
            }
        } message: {
            if deleting?.isDirectory == true { Text("A pasta e tudo o que há nela serão apagados do terminal.") }
            else { Text("O arquivo será apagado do terminal.") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await upload(urls) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await uploadPhotos(items) }
        }
    }

    private var title: String {
        guard let dir = listing?.directory ?? directory else { return terminal.name }
        if dir == place?.home { return "~" }
        return (dir as NSString).lastPathComponent.isEmpty ? dir : (dir as NSString).lastPathComponent
    }

    @ViewBuilder private var content: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if let listing {
                List {
                    Section {
                        if canGoUp {
                            Button { go(parent) } label: {
                                Label { Text(verbatim: "..") } icon: { Image(systemName: "arrow.turn.left.up") }
                                    .foregroundStyle(theme.fg)
                            }
                            .listRowBackground(theme.panel)
                        }
                        ForEach(listing.entries) { entry in row(entry) }
                    } header: {
                        Text(verbatim: listing.directory)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                    } footer: {
                        if listing.entries.isEmpty { Text("Pasta vazia.").font(.ody(size: 11)) }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load(listing.directory) }
                .accessibilityIdentifier("terminal.files.list")
            } else if loading {
                ProgressView().tint(theme.accent)
            }
            if uploading || opener.busyPath != nil {
                ProgressView().padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { newFolder = true } label: { Label("Nova pasta", systemImage: "folder.badge.plus") }
                Button { importing = true } label: { Label("Enviar arquivo", systemImage: "doc.badge.plus") }
                Button { showPhotos = true } label: { Label("Enviar foto", systemImage: "photo.badge.plus") }
                if let home = place?.home, listing?.directory != home {
                    Button { go(home) } label: { Label("Pasta inicial", systemImage: "house") }
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(listing?.writable == false)
            .accessibilityIdentifier("terminal.files.add")
        }
    }

    private func row(_ e: OWTerminalEntry) -> some View {
        Button {
            if e.isDirectory { go(e.path) } else {
                opener.open(e.path, terminal: terminal.id, session: session, client: client)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: e.isDirectory ? "folder.fill" : Self.icon(e.name))
                    .foregroundStyle(e.isDirectory ? theme.accent : theme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name).font(.ody(.subheadline)).foregroundStyle(theme.fg).lineLimit(1)
                    if let detail = detail(e) {
                        Text(verbatim: detail).font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                if opener.busyPath == e.path { ProgressView().controlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.panel)
        .contextMenu {
            if !e.isDirectory {
                Button { opener.open(e.path, terminal: terminal.id, session: session, client: client) } label: {
                    Label("Abrir", systemImage: "eye")
                }
            } else {
                Button { opener.open(e.path, isDirectory: true, terminal: terminal.id, session: session, client: client) } label: {
                    Label("Baixar como ZIP", systemImage: "doc.zipper")
                }
            }
            Button { copyPath(e.path) } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
            if e.writable {
                Button { newName = e.name; renaming = e } label: { Label("Renomear", systemImage: "pencil") }
                Button(role: .destructive) { deleting = e } label: { Label("Apagar", systemImage: "trash") }
            }
        }
        .accessibilityIdentifier("terminal.file.\(e.name)")
    }

    private func detail(_ e: OWTerminalEntry) -> String? {
        var parts: [String] = []
        if !e.isDirectory, let s = e.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
        }
        if let m = e.modified { parts.append(OWDates.dayAndTime(Date(timeIntervalSince1970: m))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func icon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "tar", "xz", "bz2": return "doc.zipper"
        case "mp3", "wav", "m4a", "flac", "ogg": return "waveform"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "py", "js", "ts", "swift", "c", "cpp", "h", "rs", "go", "java", "rb", "sh", "json", "yaml", "yml", "toml", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    // MARK: Navigation

    private var parent: String {
        let dir = listing?.directory ?? "/"
        let up = (dir as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    private var canGoUp: Bool {
        guard let dir = listing?.directory, dir != "/" else { return false }
        if let root = place?.root { return dir != root && dir.hasPrefix(root) }
        return true
    }

    private func go(_ dir: String) { Task { await load(dir) } }

    private func start() async {
        guard listing == nil else { return }
        loading = true
        do {
            let p = try await client.terminalPlace(terminal.id, session: session)
            place = p
            await load(p.cwd)
        } catch is CancellationError {
            // The sheet went away (or SwiftUI restarted the task): not an error.
        } catch {
            self.error = OWFailure.msg(error)
            await load(directory ?? "~")
        }
        loading = false
    }

    private func load(_ dir: String) async {
        do {
            listing = try await client.listTerminalFiles(terminal.id, directory: dir, session: session)
            directory = listing?.directory
        } catch is CancellationError {
        } catch {
            self.error = OWFailure.msg(error)
        }
    }

    // MARK: Changes

    private func reload() async { if let d = listing?.directory { await load(d) } }

    private func makeFolder(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains("/"), let dir = listing?.directory else { return }
        do {
            try await client.makeTerminalDirectory(terminal.id, path: Self.join(dir, n), session: session)
            await reload()
        } catch { self.error = OWFailure.msg(error) }
    }

    private func rename(_ e: OWTerminalEntry, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains("/"), n != e.name else { return }
        let dest = Self.join((e.path as NSString).deletingLastPathComponent, n)
        do {
            try await client.moveTerminalEntry(terminal.id, from: e.path, to: dest, session: session)
            await reload()
        } catch OWError.http(409, _) {
            self.error = L("Já existe %@ nesta pasta.", n)
        } catch { self.error = OWFailure.msg(error) }
    }

    private func delete(_ e: OWTerminalEntry) async {
        do {
            try await client.deleteTerminalEntry(terminal.id, path: e.path, session: session)
            await reload()
        } catch { self.error = OWFailure.msg(error) }
    }

    private func upload(_ urls: [URL]) async {
        guard let dir = listing?.directory else { return }
        uploading = true; defer { uploading = false }
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            do {
                try await client.uploadTerminalFile(terminal.id, directory: dir, data: data,
                                                    filename: url.lastPathComponent, mime: mime, session: session)
            } catch { self.error = OWFailure.msg(error); break }
        }
        await reload()
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard let dir = listing?.directory else { return }
        uploading = true; defer { uploading = false }
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let stamp = Int(Date().timeIntervalSince1970)
            let name = items.count > 1 ? "foto-\(stamp)-\(i + 1).\(ext)" : "foto-\(stamp).\(ext)"
            do {
                try await client.uploadTerminalFile(terminal.id, directory: dir, data: data, filename: name,
                                                    mime: type?.preferredMIMEType ?? "image/jpeg", session: session)
            } catch { self.error = OWFailure.msg(error); break }
        }
        await reload()
    }

    private func copyPath(_ path: String) {
        #if os(iOS)
        UIPasteboard.general.string = path
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}
