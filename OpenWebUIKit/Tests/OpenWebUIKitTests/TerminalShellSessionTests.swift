import XCTest
@testable import OpenWebUIKit

/// The interactive shell's WebSocket, against frames the terminal sends
/// (open_terminal `ws_terminal`): auth first, output announced then sent,
/// acknowledged, resumed at the cursor after a drop.
final class TerminalShellSessionTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.terminalshell")
    override func setUp() { super.setUp(); store.clear() }
    override func tearDown() { store.clear(); super.tearDown() }

    private func owClient() -> OpenWebUIClient {
        store.save(token: "tok")
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://term.test")!), tokens: store)
    }

    final class FakeSocket: OWWebSocketConnection, @unchecked Sendable {
        let lock = NSLock()
        var incoming: [URLSessionWebSocketTask.Message]
        let closeWith: Int
        var sent: [URLSessionWebSocketTask.Message] = []
        var url: URL?
        private var closed: Int?
        init(_ incoming: [URLSessionWebSocketTask.Message], closeWith: Int) {
            self.incoming = incoming; self.closeWith = closeWith
        }
        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            lock.lock(); sent.append(message); lock.unlock()
        }
        /// While set, an empty queue waits instead of closing.
        var holdOpen = false
        func receive() async throws -> URLSessionWebSocketTask.Message {
            while true {
                lock.lock()
                if !incoming.isEmpty { let m = incoming.removeFirst(); lock.unlock(); return m }
                if !holdOpen { closed = closeWith; lock.unlock(); throw URLError(.networkConnectionLost) }
                lock.unlock()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        func release() { lock.lock(); holdOpen = false; lock.unlock() }
        func close(code: Int) { lock.lock(); closed = code; lock.unlock() }
        var closeCode: Int? { lock.lock(); defer { lock.unlock() }; return closed }
        var texts: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return sent.compactMap {
                if case .string(let s) = $0 { return try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
                return nil
            }
        }
        var binaries: [Data] {
            lock.lock(); defer { lock.unlock() }
            return sent.compactMap { if case .data(let d) = $0 { return d }; return nil }
        }
    }

    final class Sockets: @unchecked Sendable {
        let lock = NSLock()
        var queue: [FakeSocket]
        var made: [FakeSocket] = []
        init(_ q: [FakeSocket]) { queue = q }
        func next(_ req: URLRequest) -> OWWebSocketConnection {
            lock.lock(); defer { lock.unlock() }
            let s = queue.isEmpty ? FakeSocket([], closeWith: 4004) : queue.removeFirst()
            s.url = req.url
            made.append(s)
            return s
        }
    }

    private func events(_ session: OWTerminalShellSession) async -> [OWTerminalShellSession.Event] {
        var out: [OWTerminalShellSession.Event] = []
        for await e in session.events { out.append(e) }
        return out
    }

    func testAuthComesFirstAndOutputIsAcknowledged() async throws {
        let s1 = FakeSocket([.string(#"{"type":"flow_control"}"#),
                             .string(#"{"type":"output","start":0,"end":5,"truncated":false}"#),
                             .data(Data("hello".utf8)),
                             .string(#"{"type":"process","pid":9,"name":"vim"}"#)], closeWith: 4004)
        let sockets = Sockets([s1])
        let session = OWTerminalShellSession(client: owClient(), terminalID: "box", shellID: "ab12", chatID: "chat-1",
                                             connect: { sockets.next($0) })
        await session.start()
        let got = await events(session)
        XCTAssertEqual(got, [.connected, .output(Data("hello".utf8)), .process("vim"), .closed(.ended)])
        XCTAssertEqual(s1.url?.absoluteString, "wss://term.test/api/v1/terminals/box/api/terminals/ab12")
        let auth = try XCTUnwrap(s1.texts.first)
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["token"] as? String, "tok")
        XCTAssertEqual(auth["chat_id"] as? String, "chat-1")
        XCTAssertEqual(auth["resume"] as? Bool, true)
        XCTAssertEqual(auth["flow_control"] as? Bool, true)
        XCTAssertEqual(auth["cursor"] as? Int, 0)
        XCTAssertTrue(s1.texts.contains { $0["type"] as? String == "ack" && $0["cursor"] as? Int == 5 })
    }

    func testADroppedSocketResumesAtTheCursor() async throws {
        let s1 = FakeSocket([.string(#"{"type":"flow_control"}"#),
                             .string(#"{"type":"output","start":0,"end":3,"truncated":false}"#),
                             .data(Data("abc".utf8))], closeWith: 1011)
        let s2 = FakeSocket([.string(#"{"type":"output","start":3,"end":5,"truncated":false}"#),
                             .data(Data("de".utf8))], closeWith: 4004)
        let sockets = Sockets([s1, s2])
        let session = OWTerminalShellSession(client: owClient(), terminalID: "box", shellID: "ab12", chatID: "chat-1",
                                             connect: { sockets.next($0) })
        await session.start()
        let got = await events(session)
        XCTAssertEqual(got, [.connected, .output(Data("abc".utf8)), .reconnecting, .connected, .output(Data("de".utf8)), .closed(.ended)])
        XCTAssertEqual(s2.texts.first?["cursor"] as? Int, 3)
    }

    func testOpenElsewhereIsSaidPlainly() async {
        let sockets = Sockets([FakeSocket([], closeWith: 4009)])
        let session = OWTerminalShellSession(client: owClient(), terminalID: "box", shellID: "ab12", chatID: nil,
                                             connect: { sockets.next($0) })
        await session.start()
        let got = await events(session)
        XCTAssertEqual(got, [.closed(.openElsewhere)])
    }

    func testAPasteGoesUpInPieces() async throws {
        let s1 = FakeSocket([.string(#"{"type":"flow_control"}"#)], closeWith: 4004)
        s1.holdOpen = true
        let sockets = Sockets([s1])
        let session = OWTerminalShellSession(client: owClient(), terminalID: "box", shellID: "ab12", chatID: "c",
                                             connect: { sockets.next($0) })
        let collected = Task { await self.events(session) }
        await session.start()
        for _ in 0..<200 where s1.texts.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await session.send(Data(repeating: 0x61, count: 40 * 1024))
        await session.resize(cols: 100, rows: 30)
        XCTAssertEqual(s1.binaries.map(\.count), [16_384, 16_384, 8_192])
        XCTAssertTrue(s1.texts.contains { $0["type"] as? String == "resize" && $0["cols"] as? Int == 100 && $0["rows"] as? Int == 30 })
        s1.release()
        let got = await collected.value
        XCTAssertEqual(got.last, .closed(.ended))
    }
}
