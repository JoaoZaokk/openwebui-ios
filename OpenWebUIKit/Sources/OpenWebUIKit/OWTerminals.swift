import Foundation

/// An Open Terminal the server lets this user reach (`GET /api/v1/terminals/`).
///
/// Open Terminal (github.com/open-webui/open-terminal) gives the model a
/// computer: a shell, files, processes. The admin connects one in Admin ›
/// Settings › Integrations, and Open WebUI proxies every route of it under
/// `/api/v1/terminals/{id}/…`, adding the terminal's own key: the app only
/// ever sends the user's token (routers/terminals.py `proxy_terminal`, 0.13.3).
public struct OWTerminalServer: Identifiable, Hashable, Sendable, Decodable {
    /// How the terminal treats chats (`contexts.chat`, utils/terminals.py
    /// `terminal_contexts`): one workspace for every chat, one per saved chat,
    /// or not offered in chats at all.
    public enum ChatScope: String, Hashable, Sendable { case shared, perChat, off }

    public var id: String
    public var name: String
    public var chatScope: ChatScope

    /// Offered in chats at all.
    public var usableInChats: Bool { chatScope != .off }
    /// Its files belong to one saved chat: the server answers 409 "A saved chat
    /// is required for this terminal" for a chat that is not on it yet.
    public var needsSavedChat: Bool { chatScope == .perChat }

    public init(id: String, name: String, chatScope: ChatScope = .shared) {
        self.id = id; self.name = name; self.chatScope = chatScope
    }

    enum CodingKeys: String, CodingKey { case id, name, contexts }
    struct Context: Decodable { var context_id: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let n = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        name = (n?.isEmpty == false ? n : nil) ?? id
        chatScope = .shared
        guard let contexts = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .contexts),
              let chat = AnyKey(stringValue: "chat"), contexts.contains(chat) else { return }
        if let on = try? contexts.decode(Bool.self, forKey: chat), on == false {
            chatScope = .off
        } else if let ctx = try? contexts.decode(Context.self, forKey: chat), ctx.context_id == "chat_id" {
            chatScope = .perChat
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// One entry of a terminal directory listing (`GET /files/list`).
public struct OWTerminalEntry: Identifiable, Hashable, Sendable {
    public var name: String
    /// Absolute path on the terminal.
    public var path: String
    public var isDirectory: Bool
    public var size: Int?
    /// Seconds since 1970.
    public var modified: Double?
    public var writable: Bool
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int? = nil,
                modified: Double? = nil, writable: Bool = true) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.size = size; self.modified = modified; self.writable = writable
    }
}

/// A directory of the terminal.
public struct OWTerminalListing: Sendable, Equatable {
    public var directory: String
    public var writable: Bool
    /// Folders first, then files, each by name.
    public var entries: [OWTerminalEntry]
}

/// Where a terminal stands: the working directory of this chat, the user's
/// home, and the top the file browser may climb to (nil: the whole disk).
public struct OWTerminalPlace: Sendable, Equatable {
    public var cwd: String
    public var home: String
    public var root: String?
    public var rootLabel: String?
}

/// A page of a text file (`GET /files/read`).
public struct OWTerminalText: Sendable, Equatable {
    public var path: String
    public var content: String
    public var totalLines: Int
}

/// A command's state and the output read so far (`POST /execute`,
/// `GET /execute/{id}/status`).
public struct OWTerminalProcess: Sendable, Equatable {
    public var id: String
    public var command: String
    /// `running`, `done`, `killed`…
    public var status: String
    public var exitCode: Int?
    /// stdout and stderr in the order they came.
    public var output: String
    /// What to pass as `offset` to read only what comes after this.
    public var nextOffset: Int
    /// Some output was left out (a `tail`, or a log that rotated).
    public var truncated: Bool

    public var isRunning: Bool { status == "running" }
}

/// An interactive shell of the terminal (`/api/terminals`).
public struct OWTerminalShell: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var pid: Int?
    public init(id: String, pid: Int? = nil) { self.id = id; self.pid = pid }
}

public extension OpenWebUIClient {

    /// The terminals this user may use. Empty when the server has none, or has
    /// external tools turned off (`ENABLE_TOOL_SERVERS`).
    func terminalServers() async throws -> [OWTerminalServer] {
        try decodeList(OWTerminalServer.self, try await send(request("/api/v1/terminals/")))
    }

    /// One call to the terminal, through the server's proxy. `session` is the
    /// chat it belongs to (`X-Session-Id`): the terminal keeps a working
    /// directory per chat, and a per-chat terminal its files.
    func terminalRequest(_ terminal: String, _ path: String, method: String = "GET",
                         query: [(String, String)] = [], json: Any? = nil,
                         session: String?, long: Bool = false) async throws -> Data {
        var req = terminalURLRequest(terminal, path, method: method, query: query, session: session)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await send(req, long: long)
    }

    /// The request `terminalRequest` sends, before any body.
    func terminalURLRequest(_ terminal: String, _ path: String, method: String = "GET",
                            query: [(String, String)] = [], session: String?) -> URLRequest {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var req = request("/api/v1/terminals/\(encPath(terminal))/\(trimmed)", method: method)
        if !query.isEmpty, let url = req.url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // `+` is a space to the server's query parser.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            req.url = comps.url
        }
        if let session, !session.isEmpty { req.setValue(session, forHTTPHeaderField: "X-Session-Id") }
        return req
    }

    // MARK: Files

    func terminalPlace(_ terminal: String, session: String?) async throws -> OWTerminalPlace {
        let obj = try Self.jsonObject(try await terminalRequest(terminal, "files/cwd", session: session))
        let root = obj["root"] as? [String: Any]
        let cwd = obj["cwd"] as? String ?? "/"
        return OWTerminalPlace(cwd: cwd, home: obj["home"] as? String ?? cwd,
                               root: root?["path"] as? String, rootLabel: root?["label"] as? String)
    }

    func listTerminalFiles(_ terminal: String, directory: String, session: String?) async throws -> OWTerminalListing {
        let obj = try Self.jsonObject(try await terminalRequest(terminal, "files/list",
                                                                query: [("directory", directory)], session: session))
        let dir = obj["dir"] as? String ?? directory
        let entries = (obj["entries"] as? [[String: Any]] ?? []).compactMap { e -> OWTerminalEntry? in
            guard let name = e["name"] as? String, !name.isEmpty else { return nil }
            return OWTerminalEntry(name: name, path: Self.join(dir, name),
                                   isDirectory: (e["type"] as? String) == "directory",
                                   size: (e["size"] as? NSNumber)?.intValue,
                                   modified: (e["modified"] as? NSNumber)?.doubleValue,
                                   writable: (e["writable"] as? Bool) ?? true)
        }
        return OWTerminalListing(directory: dir, writable: (obj["writable"] as? Bool) ?? true,
                                 entries: Self.sorted(entries))
    }

    /// Lines `from`…`to` (1-based, inclusive) of a text file. A file read
    /// whole could be any size, and the proxy holds a JSON answer in memory
    /// before it passes it on.
    func readTerminalText(_ terminal: String, path: String, from: Int = 1, to: Int = 400,
                          session: String?) async throws -> OWTerminalText {
        let data = try await terminalRequest(terminal, "files/read",
                                             query: [("path", path), ("start_line", String(from)), ("end_line", String(to))],
                                             session: session)
        let obj = try Self.jsonObject(data)
        return OWTerminalText(path: obj["path"] as? String ?? path, content: obj["content"] as? String ?? "",
                              totalLines: (obj["total_lines"] as? NSNumber)?.intValue ?? 0)
    }

    /// Downloads a file (or a folder, zipped) into a temporary file the caller
    /// owns. `preview` asks for a PDF of an Office document when the terminal
    /// can make one.
    func downloadTerminalFile(_ terminal: String, path: String, isDirectory: Bool = false,
                              preview: Bool = false, session: String?) async throws -> URL {
        var req: URLRequest
        if isDirectory {
            req = terminalURLRequest(terminal, "files/archive", method: "POST", session: session)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["paths": [path]])
        } else {
            var q = [("path", path)]
            if preview { q.append(("preview", "true")) }
            req = terminalURLRequest(terminal, "files/view", query: q, session: session)
        }
        req.timeoutInterval = 300
        req = try await withFreshToken(req)
        try permit(req)
        let (tmp, resp) = try await longSession.download(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            throw OWError.http(http.statusCode, Self.detail(from: body))
        }
        let name = (path as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(isDirectory ? name + ".zip" : (name.isEmpty ? "file" : name))
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Writes a file into `directory`, replacing one of the same name.
    @discardableResult
    func uploadTerminalFile(_ terminal: String, directory: String, data: Data, filename: String,
                            mime: String, session: String?) async throws -> String {
        var req = terminalURLRequest(terminal, "files/upload", method: "POST",
                                     query: [("directory", directory)], session: session)
        let form = OWMultipart()
        form.appendFile(name: "file", filename: filename, mime: mime, fileData: data)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized
        req.timeoutInterval = 300
        let obj = try Self.jsonObject(try await send(req, long: true))
        return obj["path"] as? String ?? Self.join(directory, filename)
    }

    func makeTerminalDirectory(_ terminal: String, path: String, session: String?) async throws {
        _ = try await terminalRequest(terminal, "files/mkdir", method: "POST", json: ["path": path], session: session)
    }

    /// Deletes a file, or a folder with everything in it.
    func deleteTerminalEntry(_ terminal: String, path: String, session: String?) async throws {
        _ = try await terminalRequest(terminal, "files/delete", method: "DELETE", query: [("path", path)], session: session)
    }

    /// Moves or renames. The terminal answers 409 when the destination exists.
    func moveTerminalEntry(_ terminal: String, from source: String, to destination: String, session: String?) async throws {
        _ = try await terminalRequest(terminal, "files/move", method: "POST",
                                      json: ["source": source, "destination": destination], session: session)
    }

    // MARK: Processes

    /// Runs a command. `wait` seconds for it to end before answering (the
    /// output comes along when it does); `tail` keeps only the last entries.
    func runTerminalCommand(_ terminal: String, command: String, cwd: String? = nil, wait: Double? = nil,
                            tail: Int? = nil, session: String?) async throws -> OWTerminalProcess {
        var body: [String: Any] = ["command": command]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        var q: [(String, String)] = []
        if let wait { q.append(("wait", Self.number(wait))) }
        if let tail { q.append(("tail", String(tail))) }
        return Self.process(try await terminalRequest(terminal, "execute", method: "POST", query: q, json: body,
                                                      session: session, long: true), command: command)
    }

    func terminalProcess(_ terminal: String, id: String, wait: Double? = nil, offset: Int = 0,
                         tail: Int? = nil, session: String?) async throws -> OWTerminalProcess {
        var q: [(String, String)] = [("offset", String(offset))]
        if let wait { q.append(("wait", Self.number(wait))) }
        if let tail { q.append(("tail", String(tail))) }
        return Self.process(try await terminalRequest(terminal, "execute/\(encPath(id))/status", query: q,
                                                      session: session, long: true), command: "")
    }

    func killTerminalProcess(_ terminal: String, id: String, session: String?) async throws {
        _ = try await terminalRequest(terminal, "execute/\(encPath(id))", method: "DELETE", session: session)
    }

    // MARK: Interactive shells

    func terminalShells(_ terminal: String, session: String?) async throws -> [OWTerminalShell] {
        try decodeList(OWTerminalShell.self, try await terminalRequest(terminal, "api/terminals", session: session))
    }

    func openTerminalShell(_ terminal: String, session: String?) async throws -> OWTerminalShell {
        try decode(OWTerminalShell.self, try await terminalRequest(terminal, "api/terminals", method: "POST", session: session))
    }

    /// Whether the shell is still there (it ends five minutes after its last
    /// client left, or when its program exits).
    func terminalShellExists(_ terminal: String, id: String, session: String?) async -> Bool {
        (try? await terminalRequest(terminal, "api/terminals/\(encPath(id))", session: session)) != nil
    }

    func closeTerminalShell(_ terminal: String, id: String, session: String?) async throws {
        _ = try await terminalRequest(terminal, "api/terminals/\(encPath(id))", method: "DELETE", session: session)
    }

    /// The WebSocket of a shell, through the proxy. The token goes in the first
    /// message, not here (routers/terminals.py `_resolve_authenticated_connection`).
    func terminalShellSocketURL(_ terminal: String, id: String) -> URL? {
        let url = config.url("/api/v1/terminals/\(encPath(terminal))/api/terminals/\(encPath(id))")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        return comps.url
    }

    // MARK: Helpers

    internal static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OWError.decoding(String(data: data.prefix(200), encoding: .utf8) ?? "not JSON")
        }
        return obj
    }

    internal static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    internal static func sorted(_ entries: [OWTerminalEntry]) -> [OWTerminalEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }

    internal static func process(_ data: Data, command: String) -> OWTerminalProcess {
        let obj = (try? jsonObject(data)) ?? [:]
        let chunks = obj["output"] as? [[String: Any]] ?? []
        return OWTerminalProcess(id: obj["id"] as? String ?? "",
                                 command: obj["command"] as? String ?? command,
                                 status: obj["status"] as? String ?? "",
                                 exitCode: (obj["exit_code"] as? NSNumber)?.intValue,
                                 output: chunks.compactMap { $0["data"] as? String }.joined(),
                                 nextOffset: (obj["next_offset"] as? NSNumber)?.intValue ?? 0,
                                 truncated: obj["truncated"] as? Bool ?? false)
    }
}
