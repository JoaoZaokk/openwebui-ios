import SwiftUI

// Cross-platform shims so the one shared SwiftUI source builds for both iOS and
// macOS. The iOS app keeps using the real UIKit-backed modifiers (these macOS
// stand-ins only compile when targeting macOS).

// MARK: - Toolbar placements (both platforms)

extension ToolbarItemPlacement {
    /// Leading edge of the bar. `.topBarLeading` on iOS, `.navigation` on macOS.
    static var odyLeading: ToolbarItemPlacement {
        #if os(macOS)
        return .navigation
        #else
        return .topBarLeading
        #endif
    }

    /// Trailing edge of the bar. `.topBarTrailing` on iOS, `.primaryAction` on macOS.
    static var odyTrailing: ToolbarItemPlacement {
        #if os(macOS)
        return .primaryAction
        #else
        return .topBarTrailing
        #endif
    }
}

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
