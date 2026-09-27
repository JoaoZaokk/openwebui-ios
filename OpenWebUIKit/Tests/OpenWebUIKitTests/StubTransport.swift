import Foundation

/// The second adapter at `OpenWebUIClient`'s transport seam.
///
/// `URLProtocol.registerClass` deliberately is not used here: it does not reach
/// a session built from `URLSessionConfiguration.default`, which is what both of
/// the client's sessions are. The class has to arrive through
/// `configuration.protocolClasses`, which is what
/// `OpenWebUIClient(config:tokens:protocolClasses:)` exists for.
///
/// Routes are matched on the request path (query ignored) so a test states the
/// endpoint it is answering, not the full URL. Everything the app sent is
/// recorded — paths in order, bodies and headers by path — so a test can assert
/// what was written, not only what was read.
final class StubTransport: URLProtocol {

    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]
        /// Seconds to hold the answer back — for a test about an answer that
        /// arrives after the app has moved on.
        var delay: TimeInterval = 0
        /// Set instead of a status: the request fails with this `URLError`.
        var failure: URLError.Code?

        init(_ status: Int = 200, _ body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status; self.body = body; self.headers = headers
        }

        /// No answer at all: the transport itself fails, the way a sleeping
        /// server or a phone in a lift does. What the app makes of that is the
        /// point of the test, not the bytes.
        static func failing(_ code: URLError.Code) -> Reply {
            var r = Reply(0)
            r.failure = code
            return r
        }

        static func json(_ raw: String, status: Int = 200) -> Reply {
            Reply(status, Data(raw.utf8), headers: ["Content-Type": "application/json"])
        }

        static func text(_ raw: String, status: Int = 200, type: String = "text/html") -> Reply {
            Reply(status, Data(raw.utf8), headers: ["Content-Type": type])
        }

        /// An SSE body delivered as one chunk. `bytes(for:)` splits it into lines
        /// regardless of how the transport chunks it.
        static func sse(_ frames: [String]) -> Reply {
            Reply(200, Data(frames.map { "data: \($0)\n\n" }.joined().utf8),
                  headers: ["Content-Type": "text/event-stream"])
        }
    }

    /// path → reply. Set before the request is made; cleared by `reset()`.
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    /// Every path this transport was asked for, in order.
    nonisolated(unsafe) private(set) static var seen: [String] = []
    /// The bodies the app sent, by path — so a test can assert what was written.
    nonisolated(unsafe) private(set) static var sentBodies: [String: Data] = [:]
    /// The headers the app sent, by path.
    nonisolated(unsafe) private(set) static var sentHeaders: [String: [String: String]] = [:]
    private static let lock = NSLock()

    static func route(_ path: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        routes[path] = reply
    }

    /// Answers the first requests to `path` with these replies, in order, then
    /// falls back to `route(_:_:)`. For a client that retries: the refusal and
    /// what the retry is answered with are two different replies.
    nonisolated(unsafe) private static var queued: [String: [Reply]] = [:]
    /// Every body sent to `path`, in order — `sentBodies` keeps only the last.
    nonisolated(unsafe) private(set) static var allBodies: [String: [Data]] = [:]

    static func routeSequence(_ path: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        queued[path] = replies
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]; seen = []; sentBodies = [:]; sentHeaders = [:]; queued = [:]; allBodies = [:]
    }

    static func requested(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.contains(path)
    }

    static func sentJSON(_ path: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let body = sentBodies[path] else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.seen.append(path)
        Self.sentHeaders[path] = request.allHTTPHeaderFields ?? [:]
        // `httpBody` is nil for a body set through a stream (multipart uploads),
        // so fall back to draining the stream.
        if let b = request.httpBody { Self.sentBodies[path] = b }
        else if let s = request.httpBodyStream { Self.sentBodies[path] = Self.drain(s) }
        if let b = Self.sentBodies[path] { Self.allBodies[path, default: []].append(b) }
        let reply: Reply?
        if var q = Self.queued[path], !q.isEmpty {
            reply = q.removeFirst(); Self.queued[path] = q
        } else {
            reply = Self.routes[path]
        }
        Self.lock.unlock()

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(
                .unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "StubTransport has no route for \(path)"]))
            return
        }

        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }

        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                   httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        let deliver = { [self] in
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}
