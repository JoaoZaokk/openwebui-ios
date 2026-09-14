import Foundation

/// Files the app can always re-create (models, diagnostics, takes waiting for
/// a transcription) stay out of iCloud/iTunes backups, per Apple's
/// data-storage guidelines. Marking a directory covers its whole subtree, and
/// callers re-apply it on every use so older installs get fixed too.
public enum OWStorage {
    public static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

/// Recordings that were finished but not yet turned into text, kept on disk so
/// that a process death during transcription — the 1.6 GB model that jetsam
/// kills, a watchdog during a long load, a dropped connection to the server —
/// costs a retry instead of the words themselves. The Redoma pattern: the file
/// is written *before* any engine is touched, and "pending" is derived from the
/// file's existence, never from a flag that could be half-written.
///
/// Apple's native recognizer is the declared exception: it consumes the mic
/// stream directly and produces partials while recording, so there is no raw
/// audio to save and a death loses less.
public enum PendingAudioStore {
    public struct Pending: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var at: Date
        public var seconds: Double
        /// The STT engine's raw value at recording time — the engine the user
        /// chose for *this* take. Resuming with whatever is selected later could
        /// send a recording made for the on-device model to a server.
        public var engine: String
        public var modelID: String
        public var language: String?
        /// Loads attempted since the file was written; bumped and persisted
        /// BEFORE the engine loads so a crash-on-load cannot loop forever.
        public var attempts: Int

        public init(id: String, at: Date, seconds: Double, engine: String, modelID: String, language: String?, attempts: Int) {
            self.id = id; self.at = at; self.seconds = seconds
            self.engine = engine; self.modelID = modelID; self.language = language; self.attempts = attempts
        }
    }

    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let maxFiles = 5
    public static let sampleRate = 16_000
    /// What a take without a sidecar is assumed to have been recorded for.
    public static let defaultEngine = "model"

    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("voice-pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        OWStorage.excludeFromBackup(d)
        return d
    }

    /// Atomic: `.part` then rename, so a kill mid-write never leaves a truncated
    /// take that the next launch would announce as a real recording.
    @discardableResult
    public static func save(frames: [Float], engine: String, modelID: String, language: String?, in dir: URL? = nil) -> Pending? {
        let dir = dir ?? directory()
        let id = UUID().uuidString.lowercased()
        let part = dir.appendingPathComponent("\(id).wav.part")
        let final = dir.appendingPathComponent("\(id).wav")
        do {
            try WAV.encode(frames, sampleRate: sampleRate).write(to: part, options: [.atomic])
            try FileManager.default.moveItem(at: part, to: final)
        } catch {
            try? FileManager.default.removeItem(at: part)
            return nil
        }
        let p = Pending(id: id, at: Date(), seconds: Double(frames.count) / Double(sampleRate),
                        engine: engine, modelID: modelID, language: language, attempts: 0)
        write(p, in: dir)
        return p
    }

    public static func write(_ p: Pending, in dir: URL? = nil) {
        let dir = dir ?? directory()
        if let d = try? JSONEncoder().encode(p) {
            try? d.write(to: dir.appendingPathComponent("\(p.id).json"), options: [.atomic])
        }
    }

    /// Oldest first. A .wav without a sidecar is still offered (duration from
    /// the file size at the store's own rate); a sidecar without a .wav is deleted.
    public static func list(in dir: URL? = nil) -> [Pending] {
        let dir = dir ?? directory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let wavs = Set(names.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) })
        var out: [Pending] = []
        for id in wavs {
            let side = dir.appendingPathComponent("\(id).json")
            if let d = try? Data(contentsOf: side), let p = try? JSONDecoder().decode(Pending.self, from: d) {
                out.append(p)
            } else {
                let wav = dir.appendingPathComponent("\(id).wav")
                let size = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let created = (try? wav.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                out.append(Pending(id: id, at: created, seconds: Double(max(0, size - 44)) / Double(2 * sampleRate),
                                   engine: defaultEngine, modelID: "", language: nil, attempts: 0))
            }
        }
        for n in names where n.hasSuffix(".json") && !wavs.contains(String(n.dropLast(5))) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
        return out.sorted { $0.at < $1.at }
    }

    public static func frames(of p: Pending, in dir: URL? = nil) -> [Float]? {
        let dir = dir ?? directory()
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(p.id).wav")), let w = WAV.decode(d) else { return nil }
        return w.frames
    }

    public static func delete(_ p: Pending, in dir: URL? = nil) {
        let dir = dir ?? directory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(p.id).wav"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(p.id).json"))
    }

    /// Bumps and persists the attempt counter; returns the updated record.
    public static func bumpAttempts(_ p: Pending, in dir: URL? = nil) -> Pending {
        var q = p; q.attempts += 1
        write(q, in: dir)
        return q
    }

    /// Drops takes older than a week and everything beyond the newest five.
    public static func purge(now: Date = Date(), in dir: URL? = nil) {
        let all = list(in: dir)
        for p in all where now.timeIntervalSince(p.at) > maxAge { delete(p, in: dir) }
        let fresh = list(in: dir)
        for p in fresh.dropLast(maxFiles) { delete(p, in: dir) }
    }
}
