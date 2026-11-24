import SwiftUI
import SwiftTerm
import OpenWebUIKit

/// Holds the shell's socket and the emulator it feeds.
@MainActor
final class TerminalShellModel: ObservableObject {
    enum State: Equatable { case starting, live, reconnecting, ended(String) }

    @Published var state: State = .starting
    @Published var program: String?

    let client: OpenWebUIClient
    let terminal: OWTerminalServer
    let chatID: String?
    private var session: OWTerminalShellSession?
    private var eventsTask: Task<Void, Never>?
    weak var view: TerminalView?
    /// Output that came before the view was there.
    private var backlog: [UInt8] = []

    init(client: OpenWebUIClient, terminal: OWTerminalServer, chatID: String?) {
        self.client = client; self.terminal = terminal; self.chatID = chatID
    }

    /// Reattaches to this chat's shell if there is one, else opens a new one.
    func start(fresh: Bool = false) async {
        state = .starting
        do {
            var shell: OWTerminalShell?
            if !fresh { shell = try await client.terminalShells(terminal.id, session: chatID).first }
            if shell == nil { shell = try await client.openTerminalShell(terminal.id, session: chatID) }
            guard let shell else { return }
            attach(shell.id)
        } catch {
            state = .ended(Self.sentence(error))
        }
    }

    private func attach(_ shellID: String) {
        eventsTask?.cancel()
        let s = OWTerminalShellSession(client: client, terminalID: terminal.id, shellID: shellID, chatID: chatID)
        session = s
        eventsTask = Task { [weak self] in
            for await e in s.events {
                guard let self else { return }
                self.handle(e)
            }
        }
        Task { await s.start() }
    }

    private func handle(_ e: OWTerminalShellSession.Event) {
        switch e {
        case .connected: state = .live
        case .output(let data): feed(Array(data))
        case .outputSkipped: feed(Array("\r\n[…]\r\n".utf8))
        case .process(let name): program = name
        case .reconnecting: state = .reconnecting
        case .closed(let why):
            switch why {
            case .ended: state = .ended(L("O shell foi encerrado."))
            case .openElsewhere: state = .ended(L("Este shell está aberto em outra janela."))
            case .refused: state = .ended(L("O servidor recusou o acesso a este terminal."))
            case .network: state = .ended(L("Sem conexão com o terminal."))
            }
        }
    }

    private func feed(_ bytes: [UInt8]) {
        if let view { view.feed(byteArray: bytes[...]) } else { backlog += bytes }
    }

    func viewReady(_ v: TerminalView) {
        view = v
        if !backlog.isEmpty { v.feed(byteArray: backlog[...]); backlog = [] }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        Task { await session?.send(data) }
    }

    func resize(cols: Int, rows: Int) { Task { await session?.resize(cols: cols, rows: rows) } }

    func suspend() { Task { await session?.suspend() } }

    func resume() {
        guard let s = session, case .live = state else { return }
        Task {
            if await client.terminalShellExists(terminal.id, id: s.shellID, session: chatID) {
                await s.start()
            } else {
                state = .ended(L("O shell foi encerrado depois de um tempo sem uso."))
            }
        }
    }

    func close() {
        eventsTask?.cancel()
        Task { await session?.stop() }
    }

    func end() async {
        guard let s = session else { return }
        await s.stop()
        try? await client.closeTerminalShell(terminal.id, id: s.shellID, session: chatID)
        state = .ended(L("O shell foi encerrado."))
    }

    private static func sentence(_ error: Error) -> String {
        if case OWError.http(429, _) = error { return L("O terminal já tem shells demais abertos. Feche algum e tente de novo.") }
        if case OWError.http(409, _) = error { return L("Este terminal só funciona em conversas salvas.") }
        return OWFailure.msg(error)
    }
}

/// The terminal's interactive shell, like the web's terminal tab.
struct TerminalShellView: View {
    @StateObject private var model: TerminalShellModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    var onOpenChanged: (Bool) -> Void = { _ in }

    init(client: OpenWebUIClient, terminal: OWTerminalServer, chatID: String?, onOpenChanged: @escaping (Bool) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: TerminalShellModel(client: client, terminal: terminal, chatID: chatID))
        self.onOpenChanged = onOpenChanged
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                TerminalEmulator(model: model)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("terminal.shell.view")
                status
            }
            .navigationTitle(Text(verbatim: model.program ?? model.terminal.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }.accessibilityIdentifier("terminal.shell.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await model.start(fresh: true) } } label: {
                            Label("Novo shell", systemImage: "plus.rectangle")
                        }
                        Button(role: .destructive) { Task { await model.end() } } label: {
                            Label("Encerrar o shell", systemImage: "xmark.octagon")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { onOpenChanged(true); await model.start() }
        .onDisappear { model.close(); onOpenChanged(false) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.suspend()
            case .active: model.resume()
            default: break
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .starting:
            ProgressView().tint(.white).padding(.top, 40)
        case .reconnecting:
            Label("Reconectando…", systemImage: "arrow.triangle.2.circlepath")
                .font(.ody(size: 12)).foregroundStyle(.white)
                .padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
        case .ended(let why):
            VStack(spacing: 10) {
                Text(verbatim: why).font(.ody(.footnote)).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("Abrir um shell novo") { Task { await model.start(fresh: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 40)
            .accessibilityIdentifier("terminal.shell.ended")
        case .live:
            EmptyView()
        }
    }
}

#if os(iOS)
private struct TerminalEmulator: UIViewRepresentable {
    let model: TerminalShellModel

    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        v.terminalDelegate = context.coordinator
        v.nativeBackgroundColor = .black
        v.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        model.viewReady(v)
        DispatchQueue.main.async { _ = v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> ShellCoordinator { ShellCoordinator(model: model) }
}
#else
private struct TerminalEmulator: NSViewRepresentable {
    let model: TerminalShellModel

    func makeNSView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        v.terminalDelegate = context.coordinator
        v.nativeBackgroundColor = .black
        v.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        model.viewReady(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> ShellCoordinator { ShellCoordinator(model: model) }
}
#endif

@MainActor
private final class ShellCoordinator: NSObject, @preconcurrency TerminalViewDelegate {
    let model: TerminalShellModel
    init(model: TerminalShellModel) { self.model = model }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { model.resize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { model.send(data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
