#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Design export — Debug builds only, never shipped.
///
/// Saves the screen on display as a PNG for editing elsewhere (Photoshop, a
/// design tool), and "the whole screen" means everything its main scroll view
/// holds, not only the part that fits: the content is scrolled a viewport at a
/// time, each slice cut out of a capture of the window, and the slices stacked
/// between the fixed top (navigation bar) and the fixed bottom (composer, tab
/// bar) of the first and last capture.
///
/// On with `-designTools YES` on the launch command line (the launchers on the
/// Desktop pass it). On the Mac it also switches the window between the size of
/// an iPhone 17 ("modo celular") and the desktop size ("modo Mac").
@MainActor
final class DesignTools: ObservableObject {
    static let shared = DesignTools()

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "designTools") }

    /// True while a capture runs: anything that must not end up in it (this
    /// tool's own button, the "jump to latest" pill) hides.
    @Published private(set) var capturing = false
    /// What the last save did, shown for a moment under the button.
    @Published var status: String?
    @AppStorage("design.phoneMode") var phoneMode = false

    private var count = 0
    private var folder: URL?

    // MARK: - Where the files go

    /// The simulator writes straight to the Mac's Desktop; an app with a sandbox
    /// (the Mac app, the iPhone app running on the Mac) asks for a folder once
    /// per launch and keeps writing there.
    private func outputFolder() async -> URL? {
        if let folder { return folder }
        let stamp = Self.stamp("yyyy-MM-dd")
        // `-designOutputDir <path>`: a fixed folder, for scripts (inside a
        // sandbox it has to be one the app may write, such as its container).
        if let fixed = UserDefaults.standard.string(forKey: "designOutputDir"), !fixed.isEmpty {
            let url = URL(fileURLWithPath: fixed)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folder = url
            return url
        }
        #if os(iOS) && targetEnvironment(simulator)
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent("Desktop/OpenWebUI-telas/\(stamp)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folder = url
            return url
        }
        #endif
        #if os(macOS)
        // The Design build of the Mac app carries the Downloads entitlement
        // (Tools/Design/OpenWebUI-macOS-Design.entitlements): no folder to pick.
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let url = downloads.appendingPathComponent("OpenWebUI-telas/\(stamp)")
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: url.path) {
                folder = url
                return url
            }
        }
        #endif
        guard let picked = await pickFolder() else { return nil }
        _ = picked.startAccessingSecurityScopedResource()
        let url = picked.appendingPathComponent("OpenWebUI-telas/\(stamp)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        return url
    }

    private static func stamp(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    private func write(_ png: Data, kind: String) async {
        guard let dir = await outputFolder() else { status = "Sem pasta escolhida"; return }
        count += 1
        let scripted = UserDefaults.standard.string(forKey: "designCaptureName") != nil
        let name = scripted ? "\(kind).png" : String(format: "%@-%03d-%@.png", Self.stamp("HHmmss"), count, kind)
        do {
            try png.write(to: dir.appendingPathComponent(name))
            status = "Salvo: \(name)"
        } catch {
            status = "Não salvou: \(error.localizedDescription)"
        }
        let shown = status
        Task { try? await Task.sleep(for: .seconds(3)); if self.status == shown { self.status = nil } }
    }

    // MARK: - Actions

    func saveFull() {
        guard !capturing else { return }
        Task {
            capturing = true
            defer { capturing = false }
            try? await Task.sleep(for: .milliseconds(250))   // let the button fade out
            guard let png = await Capture.full() else { status = "Nada para capturar"; return }
            await write(png, kind: "inteira")
        }
    }

    func saveVisible() {
        guard !capturing else { return }
        Task {
            capturing = true
            defer { capturing = false }
            try? await Task.sleep(for: .milliseconds(250))
            guard let png = Capture.visible() else { status = "Nada para capturar"; return }
            await write(png, kind: "visivel")
        }
    }

    /// `-designCaptureAfter <seconds>` saves the whole screen on its own once the
    /// launch settles (and `-designQuitAfter YES` quits after it), so a script
    /// can walk every screenshot route and export each screen unattended.
    func autoCaptureIfAsked() async {
        let wait = UserDefaults.standard.double(forKey: "designCaptureAfter")
        guard wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait))
        capturing = true
        try? await Task.sleep(for: .milliseconds(250))
        let png = await Capture.full()
        capturing = false
        if let png {
            let name = UserDefaults.standard.string(forKey: "designCaptureName") ?? "auto"
            await write(png, kind: name)
        }
        if UserDefaults.standard.bool(forKey: "designQuitAfter") { exit(0) }
    }

    func chooseFolder() {
        folder = nil
        Task { _ = await outputFolder() }
    }

    #if os(macOS)
    /// iPhone 17 is 402 × 874 points; the Mac window takes that content size in
    /// phone mode and goes back to the desktop default otherwise.
    func togglePhoneMode() {
        phoneMode.toggle()
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let size = phoneMode ? NSSize(width: 402, height: 874) : NSSize(width: 1180, height: 760)
        window.contentMinSize = phoneMode ? NSSize(width: 320, height: 560) : NSSize(width: 900, height: 560)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }
    #endif

    // MARK: - Folder picker

    #if os(iOS)
    private var pickerDelegate: FolderPickerDelegate?

    private func pickFolder() async -> URL? {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return nil }
        var top = root
        while let p = top.presentedViewController { top = p }
        return await withCheckedContinuation { cont in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            let delegate = FolderPickerDelegate { cont.resume(returning: $0) }
            pickerDelegate = delegate
            picker.delegate = delegate
            top.present(picker, animated: true)
        }
    }
    #else
    private func pickFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Salvar aqui"
        panel.message = "Pasta onde as telas vão ser salvas (uma subpasta OpenWebUI-telas é criada)"
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif
}

#if os(iOS)
private final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let done: (URL?) -> Void
    init(_ done: @escaping (URL?) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
}
#endif

// MARK: - Capture

@MainActor
private enum Capture {
    #if os(iOS)
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    static func snapshot(_ w: UIWindow) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = w.screen.scale
        f.opaque = true
        return UIGraphicsImageRenderer(bounds: w.bounds, format: f).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
    }

    static func visible() -> Data? {
        guard let w = window else { return nil }
        return snapshot(w).pngData()
    }

    /// The scroll view the screen is about: the largest vertical one that
    /// holds more than it shows, searched from the topmost presented sheet down,
    /// so a sheet's list wins over the screen behind it.
    static func mainScrollView(in w: UIWindow) -> UIScrollView? {
        var top = w.rootViewController
        while let p = top?.presentedViewController { top = p }
        for root in [top?.view, w].compactMap({ $0 }) {
            var best: (UIScrollView, CGFloat)?
            func walk(_ v: UIView) {
                guard !v.isHidden, v.alpha > 0.01 else { return }
                if let s = v as? UIScrollView, s.isScrollEnabled,
                   s.contentSize.height > s.bounds.height - s.adjustedContentInset.top - s.adjustedContentInset.bottom + 1 {
                    let r = s.convert(s.bounds, to: w).intersection(w.bounds)
                    let area = r.width * r.height
                    if r.width > w.bounds.width * 0.5, area > (best?.1 ?? 0) { best = (s, area) }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            if let best { return best.0 }
        }
        return nil
    }

    static func full() async -> Data? {
        guard let w = window else { return nil }
        guard let s = mainScrollView(in: w) else { return visible() }
        let scale = w.screen.scale
        let inset = s.adjustedContentInset
        let frame = s.convert(s.bounds, to: w)
        let top = max(0, frame.minY + inset.top)                  // first content row on screen
        let bottom = min(w.bounds.height, frame.maxY - inset.bottom)
        let viewport = bottom - top
        let content = s.contentSize.height
        guard viewport > 40 else { return visible() }
        let saved = s.contentOffset

        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        while y + viewport < content { offsets.append(y); y += viewport }
        offsets.append(max(0, content - viewport))

        let outHeight = top + content + (w.bounds.height - bottom)
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = true
        var shots: [(CGFloat, UIImage)] = []
        for o in offsets {
            s.setContentOffset(CGPoint(x: saved.x, y: o - inset.top), animated: false)
            s.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))   // lazy rows load, images decode
            shots.append((o, snapshot(w)))
        }
        s.setContentOffset(saved, animated: false)

        let size = CGSize(width: w.bounds.width, height: outHeight)
        let image = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let cg = ctx.cgContext
            // Content slices, each clipped to the visible band of its own capture.
            for (o, shot) in shots {
                cg.saveGState()
                cg.clip(to: CGRect(x: 0, y: top + o, width: size.width, height: viewport))
                shot.draw(at: CGPoint(x: 0, y: o))
                cg.restoreGState()
            }
            // The fixed top and bottom, from the first and last capture.
            if let first = shots.first?.1 {
                cg.saveGState(); cg.clip(to: CGRect(x: 0, y: 0, width: size.width, height: top))
                first.draw(at: .zero); cg.restoreGState()
            }
            if let last = shots.last {
                let band = w.bounds.height - bottom
                cg.saveGState(); cg.clip(to: CGRect(x: 0, y: outHeight - band, width: size.width, height: band))
                last.1.draw(at: CGPoint(x: 0, y: outHeight - w.bounds.height)); cg.restoreGState()
            }
        }
        return image.pngData()
    }
    #else
    static var window: NSWindow? { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The whole window, title bar and toolbar included: the content view
    /// alone leaves out the navigation title, the tabs and the buttons.
    static var frameView: NSView? { window?.contentView?.superview ?? window?.contentView }

    static func visible() -> Data? {
        guard let v = frameView, let rep = snapshot(v) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func mainScrollView(in root: NSView) -> NSScrollView? {
        var best: (NSScrollView, CGFloat)?
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if let s = v as? NSScrollView, let doc = s.documentView,
               doc.frame.height > s.contentView.bounds.height + 1 {
                let r = s.convert(s.bounds, to: root).intersection(root.bounds)
                let area = r.width * r.height
                if r.width > root.bounds.width * 0.5, area > (best?.1 ?? 0) { best = (s, area) }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best?.0
    }

    static func full() async -> Data? {
        guard let root = frameView else { return nil }
        guard let s = mainScrollView(in: root), let doc = s.documentView else { return visible() }
        let clip = s.contentView
        let flipped = root.isFlipped
        // The scroll view's visible band in root coordinates, measured from the top.
        let band = s.convert(clip.frame, to: root)
        let rootH = root.bounds.height
        let top = flipped ? band.minY : rootH - band.maxY
        let viewport = band.height
        let content = doc.frame.height
        let saved = clip.bounds.origin
        guard viewport > 40 else { return visible() }

        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        while y + viewport < content { offsets.append(y); y += viewport }
        offsets.append(max(0, content - viewport))

        var shots: [(CGFloat, NSBitmapImageRep)] = []
        for o in offsets {
            let docY = doc.isFlipped ? o : content - viewport - o
            clip.scroll(to: NSPoint(x: saved.x, y: docY))
            s.reflectScrolledClipView(clip)
            root.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            if let rep = snapshot(root) { shots.append((o, rep)) }
        }
        clip.scroll(to: saved)
        s.reflectScrolledClipView(clip)
        guard let first = shots.first?.1 else { return visible() }

        let scale = CGFloat(first.pixelsWide) / root.bounds.width
        let bottomBand = rootH - top - viewport
        let outH = top + content + bottomBand
        let W = Int(root.bounds.width * scale), H = Int(outH * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics draws from the bottom: y measured from the top becomes H - y - h.
        func draw(_ rep: NSBitmapImageRep, at originFromTop: CGFloat, clipFromTop: CGFloat, clipHeight: CGFloat) {
            guard let cg = rep.cgImage else { return }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: (outH - clipFromTop - clipHeight) * scale,
                                width: CGFloat(W), height: clipHeight * scale))
            ctx.draw(cg, in: CGRect(x: 0, y: (outH - originFromTop - rootH) * scale,
                                    width: CGFloat(W), height: rootH * scale))
            ctx.restoreGState()
        }
        for (o, rep) in shots { draw(rep, at: o, clipFromTop: top + o, clipHeight: viewport) }
        draw(first, at: 0, clipFromTop: 0, clipHeight: top)
        if let last = shots.last?.1 { draw(last, at: outH - rootH, clipFromTop: outH - bottomBand, clipHeight: bottomBand) }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
    #endif
}

// MARK: - The floating button

/// A small menu in the corner: save the whole screen (⌘⇧S), save what is
/// visible, and on the Mac the phone/desktop window switch. Hidden while it
/// captures, so it never appears in a saved screen.
struct DesignToolsOverlay: View {
    @ObservedObject private var tools = DesignTools.shared

    var body: some View {
        if !tools.capturing {
            VStack(alignment: .trailing, spacing: 6) {
                Menu {
                    Button { tools.saveFull() } label: { Text(verbatim: "Salvar tela inteira (com rolagem) ⌘⇧S") }
                    Button { tools.saveVisible() } label: { Text(verbatim: "Salvar só o que está visível ⌘⇧V") }
                    #if os(macOS)
                    Divider()
                    Button { tools.togglePhoneMode() } label: {
                        Text(verbatim: tools.phoneMode ? "Voltar ao modo Mac ⌘⇧P" : "Modo celular (iPhone 17) ⌘⇧P")
                    }
                    #endif
                    Divider()
                    Button { tools.chooseFolder() } label: { Text(verbatim: "Escolher pasta…") }
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .menuIndicator(.hidden)
                .fixedSize()
                if let s = tools.status {
                    Text(verbatim: s)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.7), in: Capsule())
                }
            }
            .padding(.trailing, 10)
            .padding(.top, 60)
            #if os(iOS)
            // The shortcuts, for a hardware keyboard and for the iPhone app
            // running on the Mac (on the Mac app they live in the Design menu).
            .background {
                Group {
                    Button("") { tools.saveFull() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("") { tools.saveVisible() }.keyboardShortcut("v", modifiers: [.command, .shift])
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
            #endif
        }
    }
}
#endif
