import SwiftUI
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import OpenWebUIKit

enum AttachImage {
    /// Downscale to `maxDimension` and return a JPEG `data:` URL (vision-ready).
    static func dataURL(from data: Data, maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> String? {
        guard let img = OWPlatformImage(data: data) else { return nil }
        let scaled = downscale(img, maxDimension: maxDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    static func downscale(_ img: OWPlatformImage, maxDimension: CGFloat) -> OWPlatformImage {
        let w = img.size.width, h = img.size.height
        let m = max(w, h)
        guard m > maxDimension else { return img }
        let scale = maxDimension / m
        let size = CGSize(width: w * scale, height: h * scale)
        #if os(macOS)
        let out = NSImage(size: size)
        out.lockFocus()
        img.draw(in: CGRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
        #else
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        #endif
    }

    /// Decode a `data:` URL into a platform image.
    static func decode(_ url: String) -> OWPlatformImage? {
        guard url.hasPrefix("data:"), let comma = url.range(of: ",") else { return nil }
        guard let d = Data(base64Encoded: String(url[comma.upperBound...])) else { return nil }
        return OWPlatformImage(data: d)
    }
}

/// Renders an attached image — a `data:` URL (decoded locally) or a server path
/// (fetched WITH the Bearer header via `client`, which plain AsyncImage can't do).
struct AttachmentThumb: View {
    let url: String
    var size: CGFloat = 56
    var client: OpenWebUIClient? = nil
    @Environment(\.theme) private var theme
    @State private var loaded: OWPlatformImage?

    var body: some View {
        Group {
            if let img = AttachImage.decode(url) ?? loaded {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { theme.panel; ProgressView().controlSize(.small) }
                    .task(id: url) {
                        if AttachImage.decode(url) == nil, let c = client,
                           let d = await c.imageData(path: url), let i = OWPlatformImage(data: d) {
                            loaded = i
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#if os(iOS)
/// UIKit camera wrapper (device only — no camera in the simulator).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(d)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// UIKit document picker — returns the picked file's data, name and mime type.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (Data, String, String) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf, .plainText, .text, .rtf, .commaSeparatedText, .json, .data],
            asCopy: true)
        p.delegate = context.coordinator
        p.allowsMultipleSelection = false
        return p
    }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ p: DocumentPicker) { parent = p }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            parent.onPick(data, url.lastPathComponent, mime)
        }
    }
}
#endif

/// Pick a note to attach (uploaded as a markdown document → RAG).
struct NotePickerSheet: View {
    let client: OpenWebUIClient
    var onPick: (OWNote) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [OWNote] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if loading { ProgressView().tint(theme.accent) }
                else if notes.isEmpty {
                    Text("Nenhuma nota.").font(.ody(.footnote, design: .monospaced)).foregroundStyle(theme.secondaryText)
                } else {
                    List(notes) { n in
                        Button { onPick(n); dismiss() } label: {
                            HStack {
                                Text(n.title).font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(theme.bg)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Anexar Nota").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .tint(theme.accent)
        .task { notes = (try? await client.notes()) ?? []; loading = false }
    }
}

/// Pick another chat to attach as reference (transcript uploaded → RAG).
struct ChatPickerSheet: View {
    let client: OpenWebUIClient
    var onPick: (OWChatSummary) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [OWChatSummary] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if loading { ProgressView().tint(theme.accent) }
                else if chats.isEmpty {
                    Text("Nenhuma conversa.").font(.ody(.footnote, design: .monospaced)).foregroundStyle(theme.secondaryText)
                } else {
                    List(chats) { c in
                        Button { onPick(c); dismiss() } label: {
                            HStack {
                                Text(c.title).font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(theme.bg)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Chats de Referência").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .tint(theme.accent)
        .task { chats = (try? await client.chats()) ?? []; loading = false }
    }
}

/// Pick a knowledge base to attach (RAG over its documents).
struct KBPickerSheet: View {
    let client: OpenWebUIClient
    var onPick: (OWNamedItem) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var items: [OWNamedItem] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if loading { ProgressView().tint(theme.accent) }
                else if items.isEmpty {
                    Text("Nenhuma base de conhecimento.")
                        .font(.ody(.footnote, design: .monospaced)).foregroundStyle(theme.secondaryText)
                } else {
                    List(items) { kb in
                        Button { onPick(kb); dismiss() } label: {
                            HStack {
                                Text(kb.name).font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).listRowBackground(theme.bg)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Base de Conhecimento").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .tint(theme.accent)
        .task { items = (try? await client.knowledgeBases()) ?? []; loading = false }
    }
}

/// Fullscreen image viewer — pinch/double-tap to zoom, with a Save button.
struct ImageViewerView: View {
    let url: String
    var client: OpenWebUIClient? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var scale: CGFloat = 1

    private var uiImage: OWPlatformImage? { AttachImage.decode(url) ?? cachedRemote }
    @State private var cachedRemote: OWPlatformImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = uiImage {
                Image(platformImage: img)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnificationGesture().onChanged { scale = $0 }.onEnded { _ in withAnimation { scale = max(1, scale) } })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    if uiImage != nil {
                        Button { save() } label: {
                            Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.title2).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding()
                Spacer()
            }
        }
        .task {
            // Server (non-data) URLs need the Bearer header — use the client.
            if AttachImage.decode(url) == nil, let c = client,
               let d = await c.imageData(path: url) {
                cachedRemote = OWPlatformImage(data: d)
            }
        }
    }

    private func save() {
        guard let img = uiImage else { return }
        owSaveImage(img)
        saved = true
    }
}
