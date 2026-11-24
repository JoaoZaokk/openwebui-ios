import SwiftUI
import OpenWebUIKit

/// What the model wants to do on the terminal, above the composer, until the
/// user answers. The reply waits for it.
struct TerminalApprovalBar: View {
    let request: OWTerminalApprovalRequest
    let answer: (_ allow: Bool, _ always: Bool) -> Void
    @Environment(\.theme) private var theme

    private var verb: String {
        switch request.tool {
        case "run_command": return L("O modelo quer rodar no terminal %@", request.terminalName)
        case "write_file": return L("O modelo quer gravar um arquivo em %@", request.terminalName)
        case "replace_file_content": return L("O modelo quer editar um arquivo em %@", request.terminalName)
        case "kill_process": return L("O modelo quer encerrar um processo em %@", request.terminalName)
        case "send_process_input", "send_user_terminal_input":
            return L("O modelo quer digitar no terminal %@", request.terminalName)
        default: return L("O modelo quer usar %@ em %@", request.tool, request.terminalName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: request.dangerous ? "exclamationmark.triangle.fill" : "terminal")
                    .foregroundStyle(request.dangerous ? Color.orange : theme.accent)
                Text(verb).font(.ody(size: 13, weight: .semibold)).foregroundStyle(theme.fg)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !request.summary.isEmpty {
                        Text(verbatim: request.tool == "run_command" ? "$ " + request.summary : request.summary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !request.detail.isEmpty {
                        Text(verbatim: request.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 160)
            .background(theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control))
            if request.dangerous {
                Text("Isto pode apagar ou mudar coisas que não voltam.")
                    .font(.ody(size: 11)).foregroundStyle(Color.orange)
            }
            HStack(spacing: 8) {
                Button(role: .cancel) { answer(false, false) } label: {
                    Text("Recusar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("terminal.deny")
                if !request.dangerous {
                    Button { answer(true, true) } label: {
                        Text("Sempre neste terminal").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("terminal.allowAlways")
                }
                Button { answer(true, false) } label: {
                    Text("Permitir").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("terminal.allow")
            }
            .font(.ody(size: 13))
        }
        .padding(12)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(request.dangerous ? Color.orange.opacity(0.7) : theme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.approval")
    }
}
