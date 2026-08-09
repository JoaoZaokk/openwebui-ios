import SwiftUI
import MarkdownUI
import OpenWebUIKit
#if os(iOS)
import UIKit
#endif

struct MessageBubble: View {
    let message: OWMessage
    var isStreaming: Bool = false
    /// Local status shown instead of the typing dots while the bubble is still
    /// empty (e.g. "Pesquisando na web…" — the server sends no progress events
    /// over plain SSE).
    var statusText: String? = nil
    var client: OpenWebUIClient? = nil
    @Environment(\.theme) private var theme
    @ObservedObject private var speech = SpeechManager.shared
    @State private var viewer: ViewerImage?

    struct ViewerImage: Identifiable { let id = UUID(); let url: String }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser { header }
                if !message.imageURLs.isEmpty { imagesView }
                if !message.documents.isEmpty { documentsView }
                if !message.content.isEmpty || (message.imageURLs.isEmpty && message.documents.isEmpty) { bubble }
                if !isUser && !message.sources.isEmpty { sourcesView }
            }
            if !isUser { Spacer(minLength: 36) }
        }
        // `.contain` (not `.combine`): VoiceOver treats the whole message as one
        // navigable group while keeping the interactive children — the speaker
        // button and image thumbnails — individually reachable. `.combine`
        // flattens interactive children out of existence.
        .accessibilityElement(children: .contain)
        .fullScreenCover(item: $viewer) { v in ImageViewerView(url: v.url, client: client) }
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
                .accessibilityLabel(Text(speech.isSpeaking(message.id) ? "Parar leitura" : "Ler em voz alta"))
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

    /// Web-search citation chips (tappable when the source has a URL).
    private var sourcesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(message.sources) { s in
                    if let u = s.url.flatMap(URL.init(string:)) {
                        Link(destination: u) { sourceChip(s) }
                    } else {
                        sourceChip(s)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceChip(_ s: OWWebSource) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "globe").font(.ody(size: 10))
            Text(s.url.flatMap { URL(string: $0)?.host } ?? s.name)
                .font(.ody(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(theme.secondaryText)
        .background(theme.panel, in: Capsule())
        .overlay(Capsule().stroke(theme.border.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if message.content.isEmpty && isStreaming {
                if let status = statusText {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini).tint(theme.secondaryText)
                        Text(status)
                            .font(.ody(size: 12, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(height: 14)
                } else {
                    TypingDots()
                }
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
                    .markdownBlockStyle(\.codeBlock) { configuration in
                        CodeBlockView(configuration: configuration)
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

/// Fenced code block: panel surface, horizontal scroll for long lines, a small
/// language chip, and a copy button for the raw code.
struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @Environment(\.theme) private var theme
    @State private var copied = false
    /// Bumped per tap so `.sensoryFeedback` fires even on rapid re-copies.
    @State private var copyTap = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced) }
                    .padding(12)
                    .padding(.trailing, 40)   // keep the first line clear of the controls
            }
            HStack(spacing: 2) {
                if let lang = configuration.language, !lang.isEmpty {
                    Text(lang)
                        .font(.ody(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.bg.opacity(0.6), in: Capsule())
                }
                copyButton
            }
            .padding(.horizontal, 4)
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.opacity(0.4), lineWidth: 1))
    }

    /// Copy-to-clipboard glyph: light haptic + a transient checkmark (~1.2s).
    private var copyButton: some View {
        Button {
            copyToClipboard(configuration.content)
            copyTap += 1
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.ody(size: 11))
                .foregroundStyle(copied ? theme.accent : theme.secondaryText)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copiar"))
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .light), trigger: copyTap)
        #endif
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Three-dot pulsing indicator while waiting for the first token.
struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(theme.fg.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == Double(i) ? 1.0 : 0.5)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { phase = 2 }
        }
        .frame(height: 14)
    }
}
