import SwiftUI

/// The one way this app reports a failure it can't recover from on its own.
///
/// It exists because the rule had no home. Every screen re-derived the banner,
/// and two of them re-derived it *inside* the branch that draws a non-empty list
/// — so the single case that matters most, "the load failed and there is nothing
/// to show", rendered "Nenhuma conversa ainda" and swallowed the reason. A shared
/// view keeps the styling honest; placing it above the content, never inside it,
/// keeps the meaning honest.
///
/// Semantic red, not the brand accent: an accent-coloured warning reads as
/// decoration.
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.ody(size: 12))
            Text(message)
                .font(.ody(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.ody(size: 11, weight: .semibold))
                    .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dispensar erro"))
        }
        .foregroundStyle(theme.danger)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.danger.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 12)
    }
}

extension View {
    /// Puts the failure above the content, so it is visible in every state the
    /// content can be in — including the empty one.
    @ViewBuilder
    func errorBanner(_ message: String?, onDismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            if let message { ErrorBanner(message: message, onDismiss: onDismiss).padding(.top, 8) }
            self
        }
    }
}
