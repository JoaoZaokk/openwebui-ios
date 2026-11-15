import AuthenticationServices
import Foundation
import Network
import OpenWebUIKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The phone's half of the browser sign-in (`OWBrowserSignInHost`): a loopback
/// HTTP listener the server's page ends by navigating to, and the system browser
/// sheet that page runs in.
///
/// The sheet is `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession
/// = false`, which is the whole point (issue #13): it is Safari, with Safari's
/// cookies, passkeys and password manager, not a web view that has none. It has
/// no callback scheme — the page's last step is a plain `http://127.0.0.1` URL,
/// which no scheme matches — so it never completes by itself; this class ends it,
/// once the listener has the code, by cancelling it.
///
/// The pure parts — what counts as the server's callback, the answer page, the
/// state comparison — are `OWLoopbackCallback` in the kit, tested there. What is
/// left here is sockets and a window, which only a device can exercise.
final class LoopbackBrowserHost: OWBrowserSignInHost, @unchecked Sendable {

    enum Failure: LocalizedError {
        case listenerFailed
        case server(String)
        case incomplete
        case timedOut
        case couldNotOpen

        var errorDescription: String? {
            switch self {
            case .listenerFailed, .incomplete: return L("Não foi possível concluir o login.")
            case .server(let why):             return why
            case .timedOut:                    return L("O login demorou demais. Tente de novo.")
            case .couldNotOpen:                return L("Não foi possível abrir o navegador.")
            }
        }
    }

    private let queue = DispatchQueue(label: "openwebui.signin.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Oldest first, so a full table can make room by dropping the longest-idle
    /// connection rather than turning the newest one away.
    private var connectionOrder: [ObjectIdentifier] = []
    private var expectedState = ""
    private var waiter: Waiter?
    private var session: ASWebAuthenticationSession?
    private var presentation: PresentationContext?
    private var timeout: Task<Void, Never>?

    /// More than a handful of simultaneous connections to a one-shot listener is
    /// not the browser; the rest are dropped.
    private static let maxConnections = 8
    /// A connection that has not said its first line in this long is not going to.
    private static let idleLimit: TimeInterval = 5

    // MARK: Listener

    func startListener() async throws -> Int {
        let params = NWParameters.tcp
        // Bound to 127.0.0.1 and nothing else: the server's validator requires
        // that literal, and a listener on every interface would answer the LAN.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw Failure.listenerFailed }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }

        let port: Int = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = l.port?.rawValue, once.fire() { cont.resume(returning: Int(p)) }
                    else if once.fire() { cont.resume(throwing: Failure.listenerFailed) }
                case .failed, .cancelled:
                    if once.fire() { cont.resume(throwing: Failure.listenerFailed) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        lock.withLock { listener = l }
        return port
    }

    private func accept(_ c: NWConnection) {
        lock.lock()
        // The newest connection wins: with the table full, the oldest is evicted.
        // Rejecting the newcomer let anything on this machine that holds eight
        // idle sockets keep the real browser callback out for the whole sign-in
        // (Auth review #6) — and the page does not retry.
        var evicted: NWConnection?
        if connections.count >= Self.maxConnections, let oldest = connectionOrder.first {
            evicted = connections[oldest]
            connections[oldest] = nil
            connectionOrder.removeFirst()
        }
        let id = ObjectIdentifier(c)
        connections[id] = c
        connectionOrder.append(id)
        lock.unlock()
        evicted?.cancel()

        c.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.forget(id) }
            if case .failed = state { c.cancel() }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.idleLimit) { c.cancel() }
        read(c, buffer: Data())
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock(); connections[id] = nil; connectionOrder.removeAll { $0 == id }; lock.unlock()
    }

    /// Reads until the request line is complete, answers it, closes. Nothing
    /// past the first line matters, and nothing is kept from the rest.
    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let line = OWLoopbackCallback.requestLine(in: buffer) {
                self.respond(to: line, on: c)
            } else if error != nil || isComplete {
                c.cancel()
            } else {
                self.read(c, buffer: buffer)
            }
        }
    }

    private func respond(to line: String, on c: NWConnection) {
        lock.lock(); let state = expectedState; let waiting = waiter; lock.unlock()
        let outcome = OWLoopbackCallback.evaluate(requestLine: line, expectedState: state)
        c.send(content: OWLoopbackCallback.response(for: outcome), contentContext: .finalMessage,
               isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        switch outcome {
        case .completed(let code): waiting?.finish(.success(code))
        case .failed(let why):     waiting?.finish(.failure(Failure.server(why)))
        case .missingCode:         waiting?.finish(.failure(Failure.incomplete))
        case .badState, .notFound, .malformed: break   // turned away; the wait goes on
        }
    }

    // MARK: Browser

    func present(pageURL: URL, expectedState: String) async throws -> String {
        let waiter = Waiter()
        lock.withLock { self.expectedState = expectedState; self.waiter = waiter }

        // The server's request is good for 600 s; so is the wait.
        timeout = Task { [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(OWBrowserSignIn.timeout * 1_000_000_000))
            waiter?.finish(.failure(Failure.timedOut))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                waiter.install(cont)
                Task { @MainActor in
                    let context = PresentationContext()
                    let s = ASWebAuthenticationSession(url: pageURL, callbackURLScheme: nil) { _, error in
                        // Only ever reached by the person closing the sheet (or by
                        // our own cancel, after the waiter is already done): there
                        // is no scheme for a URL to match.
                        if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                            waiter.finish(.failure(CancellationError()))
                        } else if let error {
                            waiter.finish(.failure(error))
                        } else {
                            waiter.finish(.failure(Failure.incomplete))
                        }
                    }
                    s.presentationContextProvider = context
                    // Safari's own session, passkeys and password manager.
                    s.prefersEphemeralWebBrowserSession = false
                    self.lock.withLock { self.session = s; self.presentation = context }
                    if !s.start() { waiter.finish(.failure(Failure.couldNotOpen)) }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    // MARK: Stop

    func stop() async {
        let (l, conns, s, w) = lock.withLock { () -> (NWListener?, [NWConnection], ASWebAuthenticationSession?, Waiter?) in
            let taken = (listener, Array(connections.values), session, waiter)
            listener = nil; connections = [:]; connectionOrder = []; session = nil; presentation = nil; waiter = nil
            return taken
        }
        timeout?.cancel(); timeout = nil
        l?.cancel()
        conns.forEach { $0.cancel() }
        // Nothing may be left waiting on a listener that is gone.
        w?.finish(.failure(CancellationError()))
        if let s { await MainActor.run { s.cancel() } }
    }

    // MARK: Pieces

    /// Resolves the one continuation exactly once, whoever gets there first.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var early: Result<String, Error>?
        private var done = false

        func install(_ c: CheckedContinuation<String, Error>) {
            lock.lock()
            if let early { lock.unlock(); c.resume(with: early); return }
            continuation = c
            lock.unlock()
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let c = continuation
            continuation = nil
            if c == nil { early = result }
            lock.unlock()
            c?.resume(with: result)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    /// Where the sheet is anchored: the window the person is looking at.
    private final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        @MainActor
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(iOS)
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
