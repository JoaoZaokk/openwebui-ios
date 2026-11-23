import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Puts the keyboard away, whoever holds it.
///
/// Build 27 tried to close the search fields with `.searchable(isPresented:)`
/// going false. That worked on the iPad simulator and not on an unfolded iPhone
/// Duo (iOS 26, regular width, the field sitting in the toolbar): the ✕ emptied
/// the field and the keyboard stayed up (video in the report on build 27).
/// Resigning the first responder is honoured by every version and size class.
@MainActor
enum Keyboard {
    static func dismiss() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension View {
    /// The search field's ✕ — the text going from something to nothing — puts
    /// the field and its keyboard away, as Cancel does on a phone held upright.
    ///
    /// The resign runs on the next turn of the main loop: the clear button
    /// empties the text while the field still holds the keyboard, and a resign
    /// sent from inside that same event can be undone by the field finishing it.
    func searchClearPutsKeyboardAway(_ text: String, presented: Binding<Bool>) -> some View {
        onChange(of: text) { old, new in
            guard !old.isEmpty, new.isEmpty else { return }
            presented.wrappedValue = false
            DispatchQueue.main.async { Keyboard.dismiss() }
        }
    }
}
