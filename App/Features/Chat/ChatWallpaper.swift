import SwiftUI
import PhotosUI
import OpenWebUIKit
#if os(iOS)
import UIKit
#endif

/// A picture behind the chat, picked in Settings (report from 1.10, zh_CN: the
/// background could only be a theme). Kept as one JPEG beside the app's data,
/// shrunk on the way in so a 12 MP photo does not sit in memory behind every chat.
struct ChatWallpaper {
    static let maxDimension: CGFloat = 1600
    /// Bumped on every change, so open chats redraw.
    static let versionKey = "chat.wallpaper.version"

    let directory: URL
    private var file: URL { directory.appendingPathComponent("chat-wallpaper.jpg") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
    }

    static let shared = ChatWallpaper()

    struct NotAPicture: Error {}

    func save(_ data: Data) throws {
        guard let img = OWPlatformImage(data: data),
              let jpeg = Self.shrunk(img).jpegData(compressionQuality: 0.8) else { throw NotAPicture() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: file, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }

    func image() -> OWPlatformImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return OWPlatformImage(data: data)
    }

    var isSet: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Pixels, not points: a renderer at the screen's scale would write a
    /// picture three times the size asked for.
    private static func shrunk(_ img: OWPlatformImage) -> OWPlatformImage {
        #if os(iOS)
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        let k = min(1, maxDimension / max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        #else
        return AttachImage.downscale(img, maxDimension: maxDimension)
        #endif
    }
}

/// The picture behind a chat, dimmed toward the theme so text stays readable.
struct ChatWallpaperLayer: View {
    @Environment(\.theme) private var theme
    @AppStorage(ChatWallpaper.versionKey) private var version = 0
    @State private var image: OWPlatformImage?

    var body: some View {
        ZStack {
            if let image {
                GeometryReader { geo in
                    Image(platformImage: image)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                theme.bg.opacity(0.55)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: version) { image = ChatWallpaper.shared.image() }
    }
}

/// Settings row: pick a picture for the chat background, or take it away.
struct ChatWallpaperRow: View {
    @Environment(\.theme) private var theme
    @AppStorage(ChatWallpaper.versionKey) private var version = 0
    @State private var item: PhotosPickerItem?
    @State private var failed = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label { Text("Fundo do chat").font(.ody(.body)).foregroundStyle(theme.fg) }
            icon: { Image(systemName: "photo").foregroundStyle(theme.accent) }
        }
        .accessibilityIdentifier("settings.chatWallpaper")
        .listRowBackground(theme.panel)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                do {
                    guard let data = try await picked.loadTransferable(type: Data.self) else { throw ChatWallpaper.NotAPicture() }
                    try ChatWallpaper.shared.save(data)
                    version += 1
                } catch {
                    failed = true
                }
                item = nil
            }
        }
        .alert(L("Não foi possível usar esta imagem."), isPresented: $failed) { Button("OK") {} }
        // Reads `version` so the row redraws when the picture comes or goes.
        if version >= 0, ChatWallpaper.shared.isSet {
            Button(role: .destructive) {
                ChatWallpaper.shared.remove()
                version += 1
            } label: {
                Label { Text("Remover fundo do chat").font(.ody(.body)) }
                icon: { Image(systemName: "photo.badge.minus") }
            }
            .accessibilityIdentifier("settings.chatWallpaper.remove")
            .listRowBackground(theme.panel)
        }
    }
}
