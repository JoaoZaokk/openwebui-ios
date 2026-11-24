import Foundation

/// One WebSocket, as the shell session needs it. The production one wraps
/// `URLSessionWebSocketTask`; tests hand in frames of their own (URLProtocol
/// does not reach WebSocket tasks).
public protocol OWWebSocketConnection: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close(code: Int)
    /// Set once the socket closed: the code the server closed it with.
    var closeCode: Int? { get }
}

public typealias OWWebSocketConnector = @Sendable (URLRequest) -> OWWebSocketConnection

final class OWURLSessionWebSocket: OWWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }
    var closeCode: Int? {
        task.closeCode == .invalid ? nil : task.closeCode.rawValue
    }
}

/// An interactive shell of an Open Terminal, through Open WebUI's proxy
/// (`/api/v1/terminals/{id}/api/terminals/{shell}`).
///
/// The protocol is the terminal's own (open_terminal `ws_terminal`): the first
/// frame is `{"type":"auth", …}` with the user's Open WebUI token (the proxy
/// swaps it for the terminal's key); keystrokes go up as binary frames, the
/// screen comes down as binary frames, each announced by an `output` frame with
/// its byte range. With `resume` + `flow_control` the client acknowledges what
/// it consumed and a reconnect resumes at that cursor — nothing printed while
/// the app was away is lost (the shell keeps 1 MiB for five minutes).
public actor OWTerminalShellSession {

    public enum Event: Sendable, Equatable {
        case connected
        /// Bytes for the terminal emulator.
        case output(Data)
        /// Some earlier output was dropped before it could be sent.
        case outputSkipped
        /// The program in the foreground (`vim`, `python`…).
        case process(String)
        case reconnecting
        /// The end: the shell exited or is gone (`4004`), it is open somewhere
        /// else (`4009`), access was refused (`4003`/`4001`), or the network
        /// stayed down.
        case closed(Reason)
    }

    public enum Reason: Sendable, Equatable {
        case ended, openElsewhere, refused, network
    }

    private let client: OpenWebUIClient
    public nonisolated let terminalID: String
    public nonisolated let shellID: String
    private let chatID: String
    private let connect: OWWebSocketConnector

    private var socket: OWWebSocketConnection?
    private var cursor = 0
    private var pendingEnd: Int?
    private var flowControlled = false
    private var stopped = false
    private var refreshedToken = false
    private var attempts = 0
    private var pingTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var size: (cols: Int, rows: Int)?

    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    /// `chatID` must be the one the shell was opened with (`X-Session-Id`):
    /// the terminal refuses a shell to another chat.
    public init(client: OpenWebUIClient, terminalID: String, shellID: String, chatID: String?,
                connect: OWWebSocketConnector? = nil) {
        self.client = client
        self.terminalID = terminalID
        self.shellID = shellID
        self.chatID = chatID ?? ""
        let session = client.longSession
        self.connect = connect ?? { OWURLSessionWebSocket(session: session, request: $0) }
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    /// Opens the socket (again, after `suspend`), resuming at the cursor.
    public func start() {
        guard !stopped, loopTask == nil else { return }
        loopTask = Task { await self.run() }
    }

    /// Closes the socket and keeps the shell: what it prints meanwhile is
    /// replayed by the next `start`. For the app going to the background — a
    /// socket iOS froze would hold the shell ("already connected") when the
    /// app comes back.
    public func suspend() {
        loopTask?.cancel(); loopTask = nil
        pingTask?.cancel(); pingTask = nil
        if let s = socket { Task { try? await s.send(.string(Self.json(["type": "activity", "active": false]))) } }
        socket?.close(code: 1000); socket = nil
    }

    /// Closes for good (the shell itself is closed through the REST route).
    public func stop() {
        stopped = true
        suspend()
        continuation.finish()
    }

    /// Typed or pasted bytes, in pieces the terminal's input queue takes
    /// (it closes the socket above 64 frames or 1 MiB waiting).
    public func send(_ data: Data) async {
        guard let socket else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 16 * 1024, data.count)
            do { try await socket.send(.data(data.subdata(in: offset..<end))) } catch { return }
            offset = end
            if offset < data.count { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        size = (cols, rows)
        try? await socket?.send(.string(Self.json(["type": "resize", "cols": cols, "rows": rows])))
    }

    // MARK: -

    private func run() async {
        while !Task.isCancelled && !stopped {
            let end = await connectOnce()
            if Task.isCancelled || stopped { return }
            switch end {
            case .closed(let reason):
                continuation.yield(.closed(reason))
                stopped = true
                continuation.finish()
                return
            case .retry:
                attempts += 1
                if attempts > 6 {
                    continuation.yield(.closed(.network)); stopped = true; continuation.finish(); return
                }
                continuation.yield(.reconnecting)
                let delay = min(10.0, pow(2.0, Double(attempts - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private enum End { case closed(Reason), retry }

    private func connectOnce() async -> End {
        guard let url = client.terminalShellSocketURL(terminalID, id: shellID) else { return .closed(.refused) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let token: String?
        do {
            token = try await client.freshToken()
            // The cleartext gate reads http(s): ws:// is http in disguise.
            var http = URLComponents(url: url, resolvingAgainstBaseURL: false)
            http?.scheme = url.scheme == "ws" ? "http" : "https"
            try client.permit(URLRequest(url: http?.url ?? url))
        } catch {
            return .closed(.refused)
        }
        let s = connect(req)
        socket = s
        flowControlled = false
        pendingEnd = nil
        do {
            try await s.send(.string(Self.json([
                "type": "auth", "token": token ?? "", "chat_id": chatID,
                "resume": true, "cursor": cursor, "flow_control": true, "process_info": true,
            ])))
            try await s.send(.string(Self.json(["type": "activity", "active": true])))
            if let size { try await s.send(.string(Self.json(["type": "resize", "cols": size.cols, "rows": size.rows]))) }
        } catch {
            return end(for: s)
        }
        startPing(s)
        var announced = false
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await s.receive() } catch { return end(for: s) }
            if !announced { announced = true; attempts = 0; refreshedToken = false; continuation.yield(.connected) }
            await handle(message, on: s)
        }
        return .retry
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on s: OWWebSocketConnection) async {
        switch message {
        case .data(let data):
            continuation.yield(.output(data))
            cursor = pendingEnd ?? (cursor + data.count)
            pendingEnd = nil
            if flowControlled {
                try? await s.send(.string(Self.json(["type": "ack", "cursor": cursor])))
            }
        case .string(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "flow_control": flowControlled = true
            case "output":
                pendingEnd = (obj["end"] as? NSNumber)?.intValue
                if obj["truncated"] as? Bool == true { continuation.yield(.outputSkipped) }
            case "process":
                if let name = obj["name"] as? String, !name.isEmpty { continuation.yield(.process(name)) }
            default: break
            }
        @unknown default: break
        }
    }

    private func end(for s: OWWebSocketConnection) -> End {
        pingTask?.cancel(); pingTask = nil
        socket = nil
        switch s.closeCode {
        case 4004?: return .closed(.ended)
        case 4009?: return .closed(.openElsewhere)
        case 4003?: return .closed(.refused)
        case 4001?:
            // A browser-made session's token lives minutes, and the proxy checks
            // it every ten seconds: renew once, then it is a real refusal.
            if refreshedToken { return .closed(.refused) }
            refreshedToken = true
            return .retry
        case 1000?: return .closed(.ended)
        default: return .retry
        }
    }

    private func startPing(_ s: OWWebSocketConnection) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { return }
                try? await s.send(.string(Self.json(["type": "ping"])))
            }
        }
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
