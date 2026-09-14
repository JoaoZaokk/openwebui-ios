import SwiftUI

// Cross-platform shims so the one shared SwiftUI source builds for both iOS and
// macOS. The iOS app keeps using the real UIKit-backed modifiers (these macOS
// stand-ins only compile when targeting macOS).

// MARK: - iOS-only view modifiers, stubbed to no-ops on macOS

#if os(macOS)

/// Mirrors `NavigationBarItem.TitleDisplayMode` (iOS-only) so call sites compile.
enum ODYTitleDisplayMode { case automatic, inline, large }

/// Mirrors `UIKeyboardType` (iOS-only). Only the cases the app uses are needed,
/// but a few extras are here for completeness.
enum ODYKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad
    case phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch
}

/// Mirrors `TextInputAutocapitalization` (iOS-only).
enum ODYTextInputAutocapitalization { case never, words, sentences, characters }

extension View {
    /// No-op on macOS — the navigation bar has no inline/large title mode there.
    func navigationBarTitleDisplayMode(_ mode: ODYTitleDisplayMode) -> some View { self }

    /// No-op on macOS — there's no software keyboard to hint.
    func keyboardType(_ type: ODYKeyboardType) -> some View { self }

    /// No-op on macOS — autocapitalization is a touch-keyboard concept.
    func textInputAutocapitalization(_ style: ODYTextInputAutocapitalization?) -> some View { self }
}

#endif

// MARK: - OpenWebUI additions: cross-platform image + covers

#if os(macOS)
import AppKit

/// One image type across platforms (NSImage on macOS, UIImage on iOS).
typealias OWPlatformImage = NSImage

extension Image {
    init(platformImage img: OWPlatformImage) { self.init(nsImage: img) }
}

extension NSImage {
    /// UIKit-parity JPEG encoder.
    func jpegData(compressionQuality q: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: q])
    }
}

/// "Save image": on the Mac that's a save panel (sandbox-friendly), not Photos.
@MainActor
func owSaveImage(_ image: OWPlatformImage) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "openwebui-image.png"
    guard panel.runModal() == .OK, let url = panel.url,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

extension ToolbarItemPlacement {
    /// iOS names, mapped to their macOS equivalents so shared call sites compile.
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

extension View {
    /// macOS has no fullScreenCover — degrade to a regular sheet.
    func fullScreenCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        sheet(item: item) { content($0).frame(minWidth: 760, minHeight: 560) }
    }
    func fullScreenCover<C: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented) { content().frame(minWidth: 760, minHeight: 560) }
    }
}

#else
import UIKit

typealias OWPlatformImage = UIImage

extension Image {
    init(platformImage img: OWPlatformImage) { self.init(uiImage: img) }
}

@MainActor
func owSaveImage(_ image: OWPlatformImage) {
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
}
#endif

// MARK: - Diagnostics: save-to-disk + clipboard, shared by both platforms

/// Writes `data` to disk and lets the user choose where it lands: a save
/// panel on macOS, the share sheet on iOS. `nil` = the user cancelled,
/// `false` = the write/share failed, `true` = it completed.
@MainActor
func owSaveJSON(_ data: Data, suggested: String) async -> Bool? {
    #if os(macOS)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggested
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do { try data.write(to: url); return true } catch { return false }
    #else
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggested)
    do { try data.write(to: url) } catch { return false }
    // Find the topmost view controller and hand the file to the share sheet.
    guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          var top = scene.keyWindow?.rootViewController else { return false }
    while let presented = top.presentedViewController { top = presented }
    return await withCheckedContinuation { cont in
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        avc.completionWithItemsHandler = { _, completed, _, error in
            try? FileManager.default.removeItem(at: url)
            if error != nil { cont.resume(returning: false) }
            else { cont.resume(returning: completed ? true : nil) }
        }
        // iPad requires a popover anchor or UIKit crashes the app.
        avc.popoverPresentationController?.sourceView = top.view
        avc.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        avc.popoverPresentationController?.permittedArrowDirections = []
        top.present(avc, animated: true)
    }
    #endif
}

func owCopyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
