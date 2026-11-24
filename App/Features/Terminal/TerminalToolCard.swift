import SwiftUI
import OpenWebUIKit

/// What ran on the terminal, under the reply: the command (or path), where it
/// stands, and its output on a tap.
struct TerminalToolCard: View {
    let tool: OWToolUse
    @Environment(\.theme) private var theme
    @Environment(\.openTerminalFile) private var openFile
    @State private var expanded = false

    private var failed: Bool {
        tool.status == "failed" || tool.status == "denied" || (tool.exitCode.map { $0 != 0 } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if tool.status == "running" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: tool.icon).font(.ody(size: 11))
                    }
                    Text(verbatim: tool.terminalHeadline)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(expanded ? 6 : 1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let s = tool.terminalStatusText {
                        Text(s).font(.ody(size: 10))
                            .foregroundStyle(failed ? Color.red.opacity(0.85) : theme.secondaryText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.ody(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("terminal.card.\(tool.action)")

            if expanded {
                if !tool.results.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: tool.results)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.fg.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(8)
                    }
                    .frame(maxHeight: 260)
                    .background(theme.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 14) {
                    if !tool.results.isEmpty {
                        Button { copy(tool.results) } label: { Label("Copiar", systemImage: "doc.on.doc") }
                    }
                    if tool.action == "display_file" || tool.action == "read_file" || tool.action == "write_file",
                       let tid = tool.terminalID, !tool.query.isEmpty, let openFile {
                        Button { openFile(TerminalFileRef(terminalID: tid, path: tool.query, page: tool.displayPage)) } label: {
                            Label("Abrir", systemImage: "eye")
                        }
                    }
                }
                .font(.ody(size: 11))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .stroke(failed ? Color.red.opacity(0.35) : theme.hairline, lineWidth: 1))
    }

    private func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
