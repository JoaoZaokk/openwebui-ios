import SwiftUI
import OpenWebUIKit

/// The message's text in a view that selects by range, so a part of an answer
/// can be copied. SwiftUI's `.textSelection` on iPhone offers the whole text
/// or nothing.
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L("Selecionar texto"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Concluído")) { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        SelectableTextView(text: text).padding(.horizontal, 12)
        #else
        // On the Mac a SwiftUI Text already selects by range.
        ScrollView { Text(verbatim: text).textSelection(.enabled).padding() }
            .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

#if os(iOS)
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        v.accessibilityIdentifier = "message.selectableText"
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}
#endif
