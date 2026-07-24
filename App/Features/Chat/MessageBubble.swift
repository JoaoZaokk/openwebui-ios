import SwiftUI
import MarkdownUI
import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#endif

struct MessageBubble: View {
    let message: OWMessage
    var isStreaming: Bool = false
    var client: OpenWebUIClient? = nil
    /// Branch position among siblings (1-based index, total) — nil when not a fork.
    var branch: (index: Int, total: Int)? = nil
    /// Models offered in the "retry with a different model" menu.
    var models: [OWModel] = []
    var onEdit: ((String) -> Void)? = nil          // edited user text
    var onRegenerate: (() -> Void)? = nil
    var onRetryModel: ((String) -> Void)? = nil    // model id
    var onBranch: ((Int) -> Void)? = nil           // ±1 to switch branch
    @Environment(\.theme) private var theme
    @ObservedObject private var speech = SpeechManager.shared
    @State private var viewer: ViewerImage?
    @State private var editing = false
    @State private var draft = ""

    struct ViewerImage: Identifiable { let id = UUID(); let url: String }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser { header }
                if !message.imageURLs.isEmpty { imagesView }
                if !message.documents.isEmpty { documentsView }
                if editing {
                    editor
                } else if !message.content.isEmpty || (message.imageURLs.isEmpty && message.documents.isEmpty) {
                    bubble.contextMenu { messageMenu }
                }
                if !editing, !isStreaming { actionBar }
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .fullScreenCover(item: $viewer) { v in ImageViewerView(url: v.url, client: client) }
    }

    /// Inline actions under a settled message: branch switcher + (assistant)
    /// regenerate / retry-with-model. Kept subtle, ChatGPT/Claude-style.
    @ViewBuilder
    private var actionBar: some View {
        let hasActions = branch != nil || (!isUser && (onRegenerate != nil || onRetryModel != nil))
        if hasActions {
            HStack(spacing: 16) {
                if let b = branch { branchNav(b) }
                if !isUser, let onRegenerate {
                    Button { onRegenerate() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                }
                if !isUser, !models.isEmpty, let onRetryModel {
                    Menu {
                        ForEach(models) { m in Button(m.shortName) { onRetryModel(m.id) } }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .font(.ody(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(.top, 1)
        }
    }

    private func branchNav(_ b: (index: Int, total: Int)) -> some View {
        HStack(spacing: 9) {
            Button { onBranch?(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(b.index <= 1)
            Text("\(b.index)/\(b.total)").font(.ody(size: 11, design: .monospaced))
            Button { onBranch?(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(b.index >= b.total)
        }
    }

    @ViewBuilder
    private var messageMenu: some View {
        if !message.content.isEmpty {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = message.content
                #endif
            } label: { Label(L("Copiar"), systemImage: "doc.on.doc") }
        }
        if isUser, onEdit != nil {
            Button { draft = message.content; editing = true } label: {
                Label(L("Editar"), systemImage: "pencil")
            }
        }
        if !isUser, let onRegenerate {
            Button { onRegenerate() } label: { Label(L("Regenerar"), systemImage: "arrow.clockwise") }
        }
    }

    /// Editable field shown in place of a user bubble while editing.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(L("Editar mensagem"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ody(.body, design: .monospaced))
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button(L("Cancelar")) { editing = false }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                Button(L("Enviar")) {
                    editing = false
                    onEdit?(draft)
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.ody(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var header: some View {
        HStack(spacing: 6) {
            BrandMark(size: 16)
            Text(message.model?.split(separator: "/").last.map(String.init) ?? "Open WebUI")
                .font(.ody(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
            if !message.content.isEmpty {
                Button { speech.toggle(message.content, id: message.id) } label: {
                    if speech.isPreparing(message.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: speech.isSpeaking(message.id) ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.ody(size: 11))
                            .foregroundStyle(speech.isSpeaking(message.id) ? theme.accent : theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var imagesView: some View {
        let cols = [GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 6)]
        return LazyVGrid(columns: cols, alignment: isUser ? .trailing : .leading, spacing: 6) {
            ForEach(message.imageURLs, id: \.self) { url in
                Button { viewer = ViewerImage(url: url) } label: {
                    AttachmentThumb(url: url, size: 120, client: client)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
    }

    private var documentsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(message.documents) { doc in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.ody(size: 12)).foregroundStyle(theme.accent)
                    Text(doc.displayName).font(.ody(size: 11, design: .monospaced))
                        .foregroundStyle(theme.fg).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(theme.panel, in: Capsule())
                .overlay(Capsule().stroke(theme.border.opacity(0.5), lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if message.content.isEmpty && isStreaming {
                TypingDots()
            } else if isUser {
                Text(message.content)
                    .font(.ody(.body, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .textSelection(.enabled)
            } else {
                Markdown(message.content)
                    .markdownTextStyle { ForegroundColor(theme.fg) }
                    .markdownTextStyle(\.code) {
                        FontFamilyVariant(.monospaced)
                        BackgroundColor(theme.panel)
                    }
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isUser ? theme.userBubble : theme.aiBubble,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border.opacity(0.35), lineWidth: isUser ? 0 : 1))
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// Three-dot pulsing indicator while waiting for the first token.
struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var animating = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(theme.fg.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.16),
                               value: animating)
            }
        }
        .onAppear { animating = true }
        .frame(height: 14)
    }
}
