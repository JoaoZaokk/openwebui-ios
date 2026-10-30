import SwiftUI
import MarkdownUI
import OpenWebUIKit
#if os(iOS)
import UIKit
#endif

struct MessageBubble: View, Equatable {
    let message: OWMessage
    var isStreaming: Bool = false
    /// Local status shown instead of the typing dots while the bubble is still
    /// empty (e.g. "Pesquisando na web…" — the server sends no progress events
    /// over plain SSE).
    var statusText: String? = nil
    var client: OpenWebUIClient? = nil
    /// Position among sibling branches (1-based index, total) — nil when this
    /// message isn't a fork point.
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
    @State private var selecting = false

    struct ViewerImage: Identifiable { let id = UUID(); let url: String }

    /// What the bubble draws. The callbacks are left out: they are rebuilt with
    /// every pass of the chat screen and act on the message by its id. Without
    /// this, each key typed in the composer rebuilt every bubble in the chat
    /// (the text lives on the same view model), and a send tapped on a long
    /// chat was lost while that ran.
    static func == (a: MessageBubble, b: MessageBubble) -> Bool {
        a.message == b.message && a.isStreaming == b.isStreaming && a.statusText == b.statusText
            && a.branch?.index == b.branch?.index && a.branch?.total == b.branch?.total
            && a.models == b.models && (a.client == nil) == (b.client == nil)
            && (a.onEdit == nil) == (b.onEdit == nil) && (a.onRegenerate == nil) == (b.onRegenerate == nil)
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser { header }
                if !isUser, !toolUses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(toolUses) { ToolUseCard(tool: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.imageURLs.isEmpty { imagesView }
                if !message.imageDocuments.isEmpty { imageDocumentsView }
                if !message.otherDocuments.isEmpty { documentsView }
                if !isUser && !message.reasoning.isEmpty {
                    ReasoningDisclosure(text: message.reasoning,
                                        streaming: isStreaming && message.content.isEmpty)
                }
                if editing {
                    editor
                } else if !message.content.isEmpty || (message.imageURLs.isEmpty && message.documents.isEmpty) {
                    bubble.contextMenu { messageMenu }
                }
                if !editing, !isStreaming { actionBar }
                if !isStreaming { timeLabel }
            }
            if !isUser, replyStyle == .bubble || replyStyle == .glass { Spacer(minLength: 36) }
        }
        // `.contain` (not `.combine`): VoiceOver treats the whole message as one
        // navigable group while keeping the interactive children — the speaker
        // button and image thumbnails — individually reachable. `.combine`
        // flattens interactive children out of existence.
        .accessibilityElement(children: .contain)
        .fullScreenCover(item: $viewer) { v in ImageViewerView(url: v.url, client: client) }
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.content) }
    }

    /// Inline actions under a settled message: branch switcher plus, on a reply,
    /// regenerate and retry-with-another-model. Deliberately subtle — it sits under
    /// every message, so it has to disappear until you look for it.
    @ViewBuilder
    private var actionBar: some View {
        // A sent message had no 🔊 anywhere — the only one lived in the reply
        // header, so what the user wrote could not be listened to at all.
        let canSpeakSent = isUser && !message.content.isEmpty
        let hasActions = branch != nil || canSpeakSent
            || (!isUser && (onRegenerate != nil || onRetryModel != nil))
        if hasActions {
            HStack(spacing: 16) {
                if canSpeakSent { speakButton(size: 12) }
                if let b = branch { branchNav(b) }
                if !isUser, let onRegenerate {
                    Button { onRegenerate() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Regenerar"))
                }
                if !isUser, !models.isEmpty, let onRetryModel {
                    Menu {
                        ForEach(models) { m in
                            Button(ModelAliases.shared.display(m)) { onRetryModel(m.id) }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel(L("Tentar com outro modelo"))
                }
            }
            .font(.ody(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(.horizontal, 2)
        }
    }

    private func branchNav(_ b: (index: Int, total: Int)) -> some View {
        HStack(spacing: 9) {
            Button { onBranch?(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(b.index <= 1)
                .accessibilityLabel(L("Resposta anterior"))
            Text(verbatim: "\(b.index)/\(b.total)")
                .font(.ody(size: 11))
            Button { onBranch?(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(b.index >= b.total)
                .accessibilityLabel(L("Próxima resposta"))
        }
    }

    @ViewBuilder
    private var messageMenu: some View {
        if !message.content.isEmpty {
            Button { speech.toggle(message.content, id: message.id) } label: {
                Label(speech.isSpeaking(message.id) ? L("Parar leitura") : L("Ler em voz alta"),
                      systemImage: "speaker.wave.2")
            }
            Button {
                #if os(iOS)
                UIPasteboard.general.string = message.content
                #endif
            } label: { Label(L("Copiar"), systemImage: "doc.on.doc") }
            // `.textSelection` on a SwiftUI Text offers only "copy all" on
            // iPhone; a part of an answer could not be copied (report from 1.10).
            Button { selecting = true } label: {
                Label(L("Selecionar texto"), systemImage: "selection.pin.in.out")
            }
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

    /// Editable field shown in place of the user bubble while editing. Sending
    /// forks a new branch instead of overwriting — the original stays reachable.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(L("Editar mensagem"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ody(.body))
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.userBubble, in: RoundedRectangle(cornerRadius: Radius.card))
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


    /// Subtle send time under each settled message (aligned with the bubble side).
    @ViewBuilder private var timeLabel: some View {
        if let t = message.timestamp {
            Text(OWDates.time(Date(timeIntervalSince1970: t)))
                .font(.ody(size: 10))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 2)
        }
    }

    /// The nickname the user gave this model, else its short id.
    private var modelLabel: String {
        guard let id = message.model, !id.isEmpty else { return "Open WebUI" }
        return ModelAliases.shared.display(id: id,
                                           fallback: id.split(separator: "/").last.map(String.init))
    }

    private var header: some View {
        HStack(spacing: 6) {
            BrandMark(size: 16)
            Text(verbatim: modelLabel)
                .font(.ody(size: 11))
                .foregroundStyle(theme.secondaryText)
            if !message.content.isEmpty { speakButton(size: 11) }
        }
    }

    /// 🔊 for this message — on a reply it sits in the header, on a sent message
    /// in the action row under the bubble.
    private func speakButton(size: CGFloat) -> some View {
        let speaking = speech.isSpeaking(message.id)
        return Button { speech.toggle(message.content, id: message.id) } label: {
            if speech.isPreparing(message.id) {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.ody(size: size))
                    .foregroundStyle(speaking ? theme.accent : theme.secondaryText)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.speak")
        .accessibilityLabel(Text(speaking ? "Parar leitura" : "Ler em voz alta"))
    }

    /// Fixed columns, not `.adaptive`: an adaptive grid claims the full width and
    /// drops a lone image into its first column, so a photo the user sent hung on
    /// the left while their bubble sat on the right. Fixed columns make the grid
    /// only as wide as its contents, and the bubble's own alignment then puts it
    /// on the correct side.
    private func thumbColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(120), spacing: 6), count: max(1, min(count, 2)))
    }

    private var imagesView: some View {
        let cols = thumbColumns(message.imageURLs.count)
        return LazyVGrid(columns: cols, alignment: isUser ? .trailing : .leading, spacing: 6) {
            // By offset, not by value: the same photo sent twice is two
            // byte-identical `data:` URLs, and identical ids made ForEach draw one.
            ForEach(Array(message.imageURLs.enumerated()), id: \.offset) { _, url in
                Button { viewer = ViewerImage(url: url) } label: {
                    AttachmentThumb(url: url, size: 120, client: client)
                        .overlay(RoundedRectangle(cornerRadius: Radius.thumb).stroke(theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 246, alignment: isUser ? .trailing : .leading)
    }

    /// Pictures the server holds by file id. Same grid as `imagesView`, resolved
    /// through the authenticated content URL — an uploaded photo used to show up
    /// as a grey pill reading "image.png".
    private var imageDocumentsView: some View {
        let cols = thumbColumns(message.imageDocuments.count)
        return LazyVGrid(columns: cols, alignment: isUser ? .trailing : .leading, spacing: 6) {
            ForEach(message.imageDocuments) { doc in
                if let client, let id = doc.id {
                    let path = client.fileContentURL(id).absoluteString
                    Button { viewer = ViewerImage(url: path) } label: {
                        AttachmentThumb(url: path, size: 120, client: client)
                            .overlay(RoundedRectangle(cornerRadius: Radius.thumb).stroke(theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 246, alignment: isUser ? .trailing : .leading)
    }

    private var documentsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(message.otherDocuments) { doc in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.ody(size: 12)).foregroundStyle(theme.accent)
                    Text(doc.displayName).font(.ody(size: 11))
                        .foregroundStyle(theme.fg).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(theme.panel, in: Capsule())
                .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
            }
        }
    }

    /// Tool cards for this reply. A chat loaded from the server carries them in
    /// `toolUses`; a search the app itself ran only produced citations, so fold
    /// those into a card too — one affordance either way, never both.
    private var toolUses: [OWToolUse] {
        if !message.toolUses.isEmpty { return message.toolUses }
        guard !message.sources.isEmpty else { return [] }
        return [OWToolUse(action: "web_search", query: "", results: "",
                          sources: message.sources.map {
                              OWSource(title: $0.name, url: $0.url ?? "")
                          })]
    }

    @AppStorage(ReplyStyle.key) private var replyStyleRaw = ReplyStyle.auto.rawValue
    private var replyStyle: ReplyStyle { (ReplyStyle(rawValue: replyStyleRaw) ?? .auto).resolved(for: theme) }
    /// Whether this bubble draws a box: always for the user's own message, and
    /// for a reply only in the boxed and glass styles.
    private var replyBoxed: Bool { isUser || replyStyle == .bubble || replyStyle == .glass }
    private var replyFill: Color {
        if isUser { return theme.userBubble }
        switch replyStyle {
        case .bubble: return theme.aiBubble
        case .glass: return theme.aiBubble.opacity(0.45)
        case .plain, .lane, .auto: return .clear
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if message.content.isEmpty && isStreaming {
                if let status = statusText {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini).tint(theme.secondaryText)
                        Text(status)
                            .font(.ody(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(height: 14)
                } else {
                    TypingDots()
                }
            } else if isUser {
                Text(message.content)
                    .font(.ody(.body))
                    .foregroundStyle(theme.fg)
                    .textSelection(.enabled)
            } else {
                Markdown(ReplyMarkup.clean(message.content))
                    // One line per newline, as on the web: options a model writes
                    // one per line were joined into a single paragraph.
                    .markdownSoftBreakMode(.lineBreak)
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
        // Markdown leaves no margin after its last block (a list, a code block),
        // so with even padding the last line sat on the bubble's bottom edge.
        .padding(.horizontal, isUser || replyStyle == .bubble || replyStyle == .glass ? 14 : 2)
        .padding(.top, isUser ? 10 : 12)
        .padding(.bottom, isUser ? 10 : 15)
        .background(replyFill, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(theme.hairline, lineWidth: isUser || !replyBoxed ? 0 : 1))
        .modifier(BubbleEffectIf(on: isUser || replyBoxed, theme: theme))
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

    /// Mermaid, SVG and HTML are drawn the way the web draws them; anything
    /// else (and a diagram that fails to parse) is the code itself.
    var body: some View {
        switch RichBlock(language: configuration.language) {
        case .mermaid?, .svg?:
            RichBlockView(kind: RichBlock(language: configuration.language)!, code: configuration.content) { codeCard }
        case .html?:
            HTMLBlockView(html: configuration.content) { codeCard }
        case nil:
            codeCard
        }
    }

    private var codeCard: some View {
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
                        .font(.ody(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.bg.opacity(0.6), in: Capsule())
                }
                copyButton
            }
            .padding(.horizontal, 4)
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(theme.hairline, lineWidth: 1))
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

/// Collapsible chain-of-thought shown above an assistant reply, mirroring the
/// extended-thinking disclosure in the Claude app. Auto-expands while the model
/// is still reasoning (no visible reply yet) and collapses once the answer lands.
struct ReasoningDisclosure: View {
    let text: String
    var streaming: Bool = false
    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var startedAt: Date?
    @State private var seconds: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if streaming {
                        ProgressView().controlSize(.mini).tint(theme.secondaryText)
                        Text(L("Pensando"))
                            .font(.ody(size: 12).weight(.semibold))
                        let line = Self.currentLine(text)
                        if !line.isEmpty {
                            Text(verbatim: "· " + line)
                                .font(.ody(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.opacity)
                                .animation(.easeOut(duration: 0.25), value: line)
                        }
                    } else {
                        Image(systemName: "brain").font(.ody(size: 11))
                        Text(seconds.map { L("Pensou por %@ s", String($0)) } ?? L("Raciocínio"))
                            .font(.ody(size: 12))
                    }
                    Image(systemName: "chevron.right")
                        .font(.ody(size: 9))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("message.reasoning")

            if expanded && !text.isEmpty {
                Text(text)
                    .font(.ody(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.border).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Timed on screen: the server keeps no duration for a reply's thinking,
        // so a reopened chat says "Raciocínio" rather than a made-up number.
        .onAppear { if streaming { startedAt = Date() } }
        .onChange(of: streaming) { _, now in
            if now { startedAt = Date() }
            else if let s = startedAt { seconds = max(1, Int(Date().timeIntervalSince(s).rounded())) }
        }
    }

    /// The line shown while the model thinks: the latest finished sentence of
    /// its last paragraph (or what there is of it so far), without Markdown,
    /// cut at 90 characters.
    static func currentLine(_ text: String) -> String {
        let lastLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        var line = lastLine
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        while let f = line.first, "-*#>• ".contains(f) { line.removeFirst() }
        // Sentences that have ended; the unfinished tail is still being written.
        var sentences: [String] = []
        var current = ""
        for ch in line {
            current.append(ch)
            if ".!?…".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
                current = ""
            }
        }
        let pick = sentences.last ?? current.trimmingCharacters(in: .whitespaces)
        return pick.count > 90 ? String(pick.prefix(89)) + "…" : pick
    }
}

/// Expandable audit card for one tool run (web search / RAG): tap to reveal the
/// raw context the model was given and tappable source links. Mirrors the
/// "searched X → here's what it saw" affordance in the Claude app.
struct ToolUseCard: View {
    let tool: OWToolUse
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: tool.icon).font(.ody(size: 11))
                    Text(tool.title).font(.ody(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    if !tool.sources.isEmpty {
                        Text("\(tool.sources.count)").font(.ody(size: 10))
                    }
                    Image(systemName: "chevron.right")
                        .font(.ody(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !tool.results.isEmpty {
                    Text(tool.results)
                        .font(.ody(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !tool.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tool.sources.enumerated()), id: \.offset) { i, s in
                            if let url = URL(string: s.url) {
                                Link(destination: url) {
                                    Text("\(i + 1). \(s.title.isEmpty ? s.url : s.title)")
                                        .font(.ody(size: 11)).foregroundStyle(theme.accent).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(theme.hairline, lineWidth: 1))
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

private struct BubbleEffectIf: ViewModifier {
    let on: Bool
    let theme: Theme
    func body(content: Content) -> some View {
        if on { content.bubbleEffect(theme) } else { content }
    }
}
