import Foundation
import os

/// One diagnostic event: a name, a timestamp and flat string props.
public struct DiagEvent: Codable, Identifiable, Sendable {
    public var name: String
    public var ts: Double
    public var props: [String: String]
    public var id: String { "\(ts)-\(name)" }
    public var date: Date { Date(timeIntervalSince1970: ts) }

    public init(name: String, ts: Double, props: [String: String]) {
        self.name = name; self.ts = ts; self.props = props
    }
}

/// The process's memory budget, the way the kernel sees it.
///
/// On iOS `os_proc_available_memory` answers "how many bytes can I still dirty
/// before jetsam kills me" — the exact ceiling a 1.6 GB Whisper checkpoint has
/// to fit under, and the number that was missing when a big model "crashed
/// with no error" (jetsam is a SIGKILL: no exception, no crash report). The
/// value is a snapshot; read it right before the allocation, never cache it.
/// macOS has no equivalent (API_UNAVAILABLE), so there only the physical total
/// is known and the gate is off.
public enum MemoryBudget {
    public static var availableBytes: Int64? {
        #if os(iOS)
        let v = os_proc_available_memory()
        return v == 0 ? nil : Int64(v)
        #else
        return nil
        #endif
    }

    public static var physicalBytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    public static var freeDiskBytes: Int64? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let v = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// Whole megabytes, for breadcrumbs and labels ("412" not "412.3 MB").
    public static func mb(_ bytes: Int64?) -> String {
        guard let bytes else { return "?" }
        return String(bytes / 1_000_000)
    }

    public static func human(_ bytes: Int64?) -> String {
        guard let bytes else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// On-disk diagnostics that survive the process: an append-only spool of
/// events, a tiny file of *open* spans, a session anchor, and the tail of the
/// speech engine's own log.
///
/// Everything that must outlive a SIGKILL is written synchronously and fsynced
/// before the risky operation runs. That is the only way to see a jetsam: the
/// kernel gives the process no chance to log its own death, so the proof is a
/// span that was opened and never closed, found on the next launch. MetricKit
/// crash payloads arrive later (and never for jetsam), so they are saved here
/// too, in the same spool, as they come.
///
/// Recording is always on — it is what makes Ajustes › Diagnóstico work on the
/// owner's own phone. Nothing is ever uploaded: the only way out is a bug
/// report the user composes and sends in their own mail app (`BugReport`).
public final class DiagnosticsStore: @unchecked Sendable {
    public static let shared = DiagnosticsStore()

    private let lock = NSLock()
    private let dir: URL
    private let spoolURL: URL
    private let rotatedURL: URL
    private let spansURL: URL
    private let sessionURL: URL
    private let engineLogURL: URL
    private var spans: [String: [String: String]] = [:]
    private var logRing: [String] = []
    private let logger = Logger(subsystem: "com.zao.openwebui", category: "diagnostics")

    private static let spoolLimit = 512 * 1024
    private static let logRingLimit = 400

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        OWStorage.excludeFromBackup(base)
        dir = base
        spoolURL = base.appendingPathComponent("spool.ndjson")
        rotatedURL = base.appendingPathComponent("spool.1.ndjson")
        spansURL = base.appendingPathComponent("spans.json")
        sessionURL = base.appendingPathComponent("session.open")
        engineLogURL = base.appendingPathComponent("engine.log")
        if let d = try? Data(contentsOf: spansURL),
           let s = try? JSONDecoder().decode([String: [String: String]].self, from: d) { spans = s }
    }

    // MARK: - Identity

    /// Which build of the app wrote the file — never which install.
    public static var appID: String {
        #if os(macOS)
        "openwebui-macos"
        #else
        "openwebui-ios"
        #endif
    }

    // MARK: - Events

    public func event(_ name: String, _ props: [String: String] = [:]) {
        let e = DiagEvent(name: name, ts: Date().timeIntervalSince1970, props: props)
        guard let line = try? JSONEncoder().encode(e) else { return }
        lock.lock(); defer { lock.unlock() }
        append(line, to: spoolURL)
        rotateIfNeeded()
        logger.info("\(name, privacy: .public) \(props.description, privacy: .public)")
    }

    /// Newest last. Reads the rotated file first so order is chronological.
    public func recentEvents(limit: Int = 200) -> [DiagEvent] {
        lock.lock(); defer { lock.unlock() }
        var out: [DiagEvent] = []
        for u in [rotatedURL, spoolURL] {
            guard let d = try? Data(contentsOf: u), let s = String(data: d, encoding: .utf8) else { continue }
            for line in s.split(separator: "\n") {
                if let e = try? JSONDecoder().decode(DiagEvent.self, from: Data(line.utf8)) { out.append(e) }
            }
        }
        return Array(out.suffix(limit))
    }

    /// Drops everything up to and including the given timestamp.
    public func drop(upTo ts: Double) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: rotatedURL)
        guard let d = try? Data(contentsOf: spoolURL), let s = String(data: d, encoding: .utf8) else { return }
        let keep = s.split(separator: "\n").filter { line in
            guard let e = try? JSONDecoder().decode(DiagEvent.self, from: Data(line.utf8)) else { return false }
            return e.ts > ts
        }
        try? (keep.joined(separator: "\n") + (keep.isEmpty ? "" : "\n")).write(to: spoolURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Spans (breadcrumbs that prove a silent death)

    /// Writes the span to disk (fsync) BEFORE the caller does the risky thing.
    public func beginSpan(_ name: String, _ props: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var p = props
        p["at"] = String(Date().timeIntervalSince1970)
        spans[name] = p
        persistSpans()
        logger.info("span.begin \(name, privacy: .public) \(props.description, privacy: .public)")
    }

    /// Closes the span and records `<name>.ok` with the elapsed milliseconds.
    public func endSpan(_ name: String, _ extra: [String: String] = [:]) {
        lock.lock()
        let opened = spans.removeValue(forKey: name)
        persistSpans()
        lock.unlock()
        var p = extra
        if let at = opened?["at"].flatMap(Double.init) { p["ms"] = String(Int((Date().timeIntervalSince1970 - at) * 1000)) }
        event("\(name).ok", p)
    }

    /// Closes the span as failed (an error the process survived).
    public func failSpan(_ name: String, _ error: String) {
        lock.lock()
        let opened = spans.removeValue(forKey: name)
        persistSpans()
        lock.unlock()
        var p = opened ?? [:]
        p["error"] = String(error.prefix(300))
        event("\(name).fail", p)
    }

    public func openSpans() -> [String: [String: String]] { lock.lock(); defer { lock.unlock() }; return spans }

    // MARK: - Session anchors

    /// Call once at launch: turns spans left open by the previous process into
    /// `death.suspected` events, notes an abnormal end, then marks this session.
    public func startSession(version: String, build: String) {
        let leftovers = openSpans()
        for (name, props) in leftovers {
            var p = props; p["span"] = name
            event("death.suspected", p)
        }
        lock.lock()
        spans.removeAll(); persistSpans()
        let abnormal = FileManager.default.fileExists(atPath: sessionURL.path)
        try? Data("1".utf8).write(to: sessionURL)
        lock.unlock()
        if abnormal && leftovers.isEmpty { event("session.abnormal_end") }
        event("session.begin", ["version": version, "build": build, "physMB": MemoryBudget.mb(MemoryBudget.physicalBytes)])
    }

    public func endSession() {
        lock.lock()
        try? FileManager.default.removeItem(at: sessionURL)
        lock.unlock()
        event("session.end")
    }

    /// Back to the foreground: mark the session open again so a death from
    /// here on is still recognised as abnormal.
    public func resumeSession() {
        lock.lock()
        let wasOpen = FileManager.default.fileExists(atPath: sessionURL.path)
        try? Data("1".utf8).write(to: sessionURL)
        lock.unlock()
        if !wasOpen { event("session.resume") }
    }

    /// The latest silent death, for the Diagnostics screen.
    public func lastSuspectedDeath() -> DiagEvent? {
        recentEvents(limit: 2000).last { $0.name == "death.suspected" || $0.name == "session.abnormal_end" }
    }

    // MARK: - Engine log (whisper.cpp / ggml lines)

    public func appendEngineLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        logRing.append(trimmed)
        if logRing.count > Self.logRingLimit { logRing.removeFirst(logRing.count - Self.logRingLimit) }
        append(Data((trimmed + "\n").utf8), to: engineLogURL)
        if let size = try? engineLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256 * 1024 {
            try? (logRing.joined(separator: "\n") + "\n").write(to: engineLogURL, atomically: true, encoding: .utf8)
        }
    }

    public func engineLogTail(_ n: Int = 120) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if logRing.isEmpty, let s = try? String(contentsOf: engineLogURL, encoding: .utf8) {
            logRing = s.split(separator: "\n").map(String.init).suffix(Self.logRingLimit).map { $0 }
        }
        return Array(logRing.suffix(n))
    }

    // MARK: - Blobs (raw MetricKit payloads, last 20)

    public func saveBlob(_ data: Data, kind: String, at date: Date) {
        let base = dir.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(date.timeIntervalSince1970)).json"
        try? data.write(to: base.appendingPathComponent(name), options: [.atomic])
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
        for old in files.dropLast(20) { try? FileManager.default.removeItem(at: base.appendingPathComponent(old)) }
    }

    // MARK: - Export

    /// Everything the screen shows, as one JSON document (share sheet / save panel).
    public func exportJSON() -> Data {
        let env: [String: Any] = [
            "app": Self.appID,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physMB": MemoryBudget.mb(MemoryBudget.physicalBytes),
            "availMB": MemoryBudget.mb(MemoryBudget.availableBytes),
            "openSpans": openSpans(),
            "events": recentEvents(limit: 2000).map { ["name": $0.name, "ts": $0.ts, "props": $0.props] as [String: Any] },
            "engineLog": engineLogTail(400),
        ]
        return (try? JSONSerialization.data(withJSONObject: env, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: - Files

    private func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
        try? h.synchronize()
    }

    private func rotateIfNeeded() {
        guard let size = try? spoolURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.spoolLimit else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: spoolURL, to: rotatedURL)
    }

    private func persistSpans() {
        guard let d = try? JSONEncoder().encode(spans) else { return }
        try? d.write(to: spansURL, options: [.atomic])
        if let h = try? FileHandle(forReadingFrom: spansURL) { try? h.synchronize(); try? h.close() }
    }
}
