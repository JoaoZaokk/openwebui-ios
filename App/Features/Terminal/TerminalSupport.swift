import SwiftUI
import OpenWebUIKit

/// A file of a terminal to show: from `display_file`, or a tap in a card.
struct TerminalFileRef: Identifiable, Equatable {
    var terminalID: String
    var path: String
    var page: Int?
    var id: String { terminalID + "|" + path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Terminals the user said "always allow" for, per server. A command that
/// looks destructive is still asked about.
enum TerminalTrust {
    private static let key = "terminal.alwaysAllow"

    private static var all: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func id(_ server: String, _ terminal: String) -> String { server + "|" + terminal }

    static func isTrusted(server: String, terminal: String) -> Bool {
        all.contains(id(server, terminal))
    }

    static func trust(server: String, terminal: String) {
        var s = all
        s.insert(id(server, terminal))
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
    }

    static func revoke(server: String, terminal: String) {
        var s = all
        s.remove(id(server, terminal))
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
    }

    static func revokeAll() { UserDefaults.standard.removeObject(forKey: key) }

    static var count: Int { all.count }
}

/// Opens a terminal file from inside a message (a `display_file` card).
private struct OpenTerminalFileKey: EnvironmentKey {
    static let defaultValue: ((TerminalFileRef) -> Void)? = nil
}

extension EnvironmentValues {
    var openTerminalFile: ((TerminalFileRef) -> Void)? {
        get { self[OpenTerminalFileKey.self] }
        set { self[OpenTerminalFileKey.self] = newValue }
    }
}

extension OWToolUse {
    /// The line a terminal card shows in its header.
    var terminalHeadline: String {
        switch action {
        case "run_command": return query.isEmpty ? title : "$ " + query
        default: return query.isEmpty ? title : query
        }
    }

    var terminalStatusText: String? {
        switch status {
        case "approval": return L("Aguardando sua confirmação")
        case "running": return L("Rodando…")
        case "denied": return L("Recusado")
        case "failed": return L("Falhou")
        default:
            if let code = exitCode { return code == 0 ? nil : L("Saiu com código %lld", code) }
            return nil
        }
    }
}
