import SwiftUI
import OpenWebUIKit

/// Which terminal this chat works with, and the way into its files and shell.
struct TerminalPickerSheet: View {
    @ObservedObject var vm: ChatViewModel
    let terminals: [OWTerminalServer]
    var openFiles: () -> Void
    var openShell: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var trusted = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(nil)
                    ForEach(terminals) { row($0) }
                } footer: {
                    Text("Com um terminal, o modelo pode ler e gravar arquivos e rodar comandos nele. Antes de mudar qualquer coisa, ele pede a sua confirmação.")
                        .font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                }
                if let t = vm.terminal {
                    Section {
                        Button { dismiss(); openFiles() } label: {
                            Label("Arquivos do terminal", systemImage: "folder")
                        }
                        .accessibilityIdentifier("terminal.files")
                        Button { dismiss(); openShell() } label: {
                            Label("Abrir o shell", systemImage: "terminal")
                        }
                        .accessibilityIdentifier("terminal.shell")
                        if trusted {
                            Button(role: .destructive) {
                                TerminalTrust.revoke(server: vm.serverKey, terminal: t.id)
                                trusted = false
                            } label: {
                                Label("Voltar a pedir confirmação", systemImage: "hand.raised")
                            }
                        }
                    } header: {
                        Text(t.name)
                    } footer: {
                        if !vm.modelSupportsTerminal {
                            Text("O administrador desligou o terminal para este modelo. Os arquivos e o shell continuam abertos para você.")
                                .font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("Terminal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
            .onAppear { refreshTrust() }
            .onChange(of: vm.terminalID) { _, _ in refreshTrust() }
        }
        .tint(theme.accent)
    }

    private func refreshTrust() {
        trusted = vm.terminalID.map { TerminalTrust.isTrusted(server: vm.serverKey, terminal: $0) } ?? false
    }

    private func disabled(_ t: OWTerminalServer) -> Bool { t.needsSavedChat && vm.temporary }

    private func row(_ t: OWTerminalServer?) -> some View {
        let on = vm.terminalID == t?.id
        return Button {
            if let t, disabled(t) { return }
            vm.terminalID = t?.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.ody(size: 14)).foregroundStyle(on ? theme.accent : theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    (t.map { Text(verbatim: $0.name) } ?? Text("Nenhum"))
                        .font(.ody(.subheadline)).foregroundStyle(theme.fg)
                    if let t, t.needsSavedChat {
                        Text(vm.temporary ? "Só em conversas salvas" : "Arquivos separados por conversa")
                            .font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .opacity(t.map(disabled) == true ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.panel)
        .accessibilityIdentifier("terminal.option.\(t?.id ?? "none")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
