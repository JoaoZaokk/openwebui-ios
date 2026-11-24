import Foundation
import os
import SwiftUI
import ZIPFoundation
import OpenWebUIKit

/// Downloads and stores speech models **on the device** (no Mac involved).
/// Handles both the Whisper GGUF (.bin) and the optional CoreML encoder
/// (.mlmodelc, downloaded as a zip and unpacked next to the .bin so whisper.cpp
/// runs on the Neural Engine instead of the CPU). CoreML task ids are prefixed
/// with "ml:".
@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var coreMLInstalled: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]   // key: model id, or "ml:"+id
    @Published var error: String?

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// What URLSession hands back when a download is cut off (the app left the
    /// foreground, the network dropped): the next tap on Baixar continues from
    /// there instead of starting a 3 GB file over. Lives only as long as the
    /// process — the bytes it points at are swept on the next launch.
    private var resumeData: [String: Data] = [:]

    nonisolated static func modelsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        excludeFromBackup(d)
        return d
    }

    /// Keeps re-downloadable model files out of iCloud/iTunes backups, per
    /// Apple's data-storage guidelines — otherwise every 500 MB checkpoint the
    /// user tries rides along in their backup forever. Marking the directory
    /// covers its whole subtree, and it's re-applied on each call so installs
    /// created before this existed get fixed too.
    nonisolated static func excludeFromBackup(_ url: URL) { OWStorage.excludeFromBackup(url) }
    private let dir = ModelDownloadManager.modelsDir()

    override init() {
        super.init()
        refresh()
    }

    /// Called once from the app's `init`, before any URLSession exists — this
    /// manager's or FluidAudio's (the neural voices download through their own).
    /// Off the main thread: a multi-GB partial takes a moment to unlink.
    nonisolated static func sweepPartialDownloadsAtLaunch() {
        DispatchQueue.global(qos: .utility).async {
            let freed = sweepPartialDownloads()
            if freed > 0 { DiagnosticsStore.shared.event("download.swept", ["freedMB": MemoryBudget.mb(freed)]) }
        }
    }

    /// Deletes what interrupted downloads left behind and returns the bytes freed.
    ///
    /// URLSession writes a download into `tmp/` as `CFNetworkDownload_*.tmp`,
    /// and when one is cut off it keeps that file so the download can resume.
    /// Resuming needs the resume data, which only the process that saw the
    /// failure holds — once the app has quit the half file belongs to no one.
    /// Report on build 27: leave the app during a download, come back to the
    /// error, and half of a 3 GB model stayed on the phone. Also takes the
    /// `ml-*` folders a Core ML unpack killed halfway leaves (see
    /// `unpackCoreML`).
    @discardableResult
    nonisolated static func sweepPartialDownloads(in tmp: URL = FileManager.default.temporaryDirectory) -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) else { return 0 }
        var freed: Int64 = 0
        for url in items {
            let name = url.lastPathComponent
            let partial = name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp")
            let unpack = name.hasPrefix("ml-") && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard partial || unpack else { continue }
            let size = OWStorage.allocatedSize(of: url)
            if (try? fm.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    // MARK: - Paths / state

    func localURL(_ model: VoiceModel) -> URL { dir.appendingPathComponent("\(model.id)-\(model.filename)") }
    private func coreMLFolderURL(_ model: VoiceModel) -> URL {
        dir.appendingPathComponent(Self.coreMLFolderName(id: model.id, filename: model.filename))
    }
    /// The folder name whisper.cpp itself looks for next to the .bin: the
    /// extension AND a trailing `-qD_D` quantization suffix are dropped before
    /// `-encoder.mlmodelc` (src/whisper.cpp, `whisper_get_coreml_path_encoder`).
    /// An earlier build kept the suffix, so `w-turbo-q5-ggml-large-v3-turbo-q5_0-encoder.mlmodelc`
    /// was installed while whisper.cpp opened `…-turbo-encoder.mlmodelc`, failed
    /// quietly (ALLOW_FALLBACK) and ran the whole encoder without the Neural
    /// Engine — the "700 MB model takes forever" report.
    nonisolated static func coreMLFolderName(id: String, filename: String) -> String {
        WhisperRules.coreMLEncoderPath(forModelAt: "\(id)-\(filename)")
    }
    /// What the earlier build wrote; `refresh()` renames these into place.
    nonisolated static func legacyCoreMLFolderName(id: String, filename: String) -> String {
        WhisperRules.legacyCoreMLEncoderPath(forModelAt: "\(id)-\(filename)")
    }

    func isInstalled(_ model: VoiceModel) -> Bool { installed.contains(model.id) }
    func isDownloading(_ model: VoiceModel) -> Bool { tasks[model.id] != nil }
    func coreMLAvailable(_ model: VoiceModel) -> Bool { VoiceCatalog.coreMLZipURL(forID: model.id) != nil }
    func hasCoreML(_ model: VoiceModel) -> Bool { coreMLInstalled.contains(model.id) }
    func coreMLProgress(_ model: VoiceModel) -> Double? { progress["ml:\(model.id)"] }
    func isDownloadingCoreML(_ model: VoiceModel) -> Bool { tasks["ml:\(model.id)"] != nil }

    func refresh() {
        var files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        // Migrate encoders installed under the legacy name to the one
        // whisper.cpp reads.
        for m in VoiceCatalog.all {
            let legacy = Self.legacyCoreMLFolderName(id: m.id, filename: m.filename)
            let wanted = Self.coreMLFolderName(id: m.id, filename: m.filename)
            guard legacy != wanted, files.contains(legacy), !files.contains(wanted) else { continue }
            if (try? FileManager.default.moveItem(at: dir.appendingPathComponent(legacy), to: dir.appendingPathComponent(wanted))) != nil {
                files.remove(legacy); files.insert(wanted)
                DiagnosticsStore.shared.event("coreml.migrated", ["model": m.id])
            }
        }
        installed = Set(VoiceCatalog.all.filter { files.contains("\($0.id)-\($0.filename)") }.map(\.id))
        coreMLInstalled = Set(VoiceCatalog.all.filter { files.contains(Self.coreMLFolderName(id: $0.id, filename: $0.filename)) }.map(\.id))
    }

    /// Bytes the Core ML encoder adds to RAM once installed (0 = none / unknown).
    func coreMLBytes(_ model: VoiceModel) -> Int64 {
        hasCoreML(model) ? VoiceCatalog.coreMLZipBytes(forID: model.id) : 0
    }

    // MARK: - GGUF model

    func download(_ model: VoiceModel) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        error = nil
        if let free = Self.freeBytes(), free < model.bytes + 50_000_000 {
            error = AddError.noSpace(model.bytes).errorDescription
            DiagnosticsStore.shared.event("download.refused", ["model": model.id, "freeMB": MemoryBudget.mb(free)])
            return
        }
        let resuming = resumeData.removeValue(forKey: model.id)
        DiagnosticsStore.shared.event("download.start", ["model": model.id, "bytes": String(model.bytes),
                                                         "resume": resuming == nil ? "0" : "1"])
        progress[model.id] = 0
        Self.progressGate.withLock { $0[model.id] = nil }
        let task = resuming.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: VoiceModel) {
        tasks[model.id]?.cancel(); tasks[model.id] = nil; progress[model.id] = nil
        dropResumeData(model.id)
    }

    /// Forgets a resumable download. Its half file stays in tmp until the
    /// next launch's sweep: which file a resume blob points at is written in a
    /// private keyed archive, and deleting by guess could take a neural voice's
    /// download that is still running.
    private func dropResumeData(_ id: String) {
        resumeData[id] = nil
    }

    func delete(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: localURL(model))
        installed.remove(model.id)
        // The context stays resident otherwise (deleting freed disk, not RAM),
        // and a selected-but-deleted id only fails later, mid-dictation.
        STTRunner.shared.releaseIfLoaded(id: model.id)
        if UserDefaults.standard.string(forKey: "voice.stt.model") == model.id {
            UserDefaults.standard.removeObject(forKey: "voice.stt.model")
        }
        DiagnosticsStore.shared.event("model.deleted", ["model": model.id])
        deleteCoreML(model)   // the encoder is useless without the model
        // A user-added model has no catalog entry to fall back to — deleting the
        // file must also drop the registration, or the list keeps a dead row.
        if model.isCustom { CustomModels.remove(id: model.id) }
    }

    // MARK: - User-supplied model URLs

    enum AddError: LocalizedError {
        case notHTTPS, unreachable(String), noSpace(Int64), notAWhisperModel

        var errorDescription: String? {
            switch self {
            case .notHTTPS:
                return L("Use um link https.")
            case .unreachable(let why):
                return L("Não consegui acessar esse link: %@", why)
            case .noSpace(let need):
                return L("Espaço insuficiente: são necessários %@ livres.",
                         ByteCountFormatter.string(fromByteCount: need, countStyle: .file))
            case .notAWhisperModel:
                return L("Não parece um modelo Whisper ggml. Confira se o link aponta para o arquivo, não para a página.")
            }
        }
    }

    /// Normalizes a pasted link and starts the download.
    ///
    /// Rejects anything but https (App Transport Security blocks cleartext, and
    /// an unencrypted model download is trivially tamperable), and rewrites the
    /// Hugging Face *page* URL into the file URL — pasting the `/blob/` link is
    /// the single most common mistake and otherwise downloads an HTML page that
    /// only fails much later, at load time.
    func addCustomModel(from raw: String) async throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var comps = URLComponents(string: text), let host = comps.host else {
            throw AddError.notHTTPS
        }
        guard comps.scheme?.lowercased() == "https" else { throw AddError.notHTTPS }
        if host.hasSuffix("huggingface.co"), let r = comps.path.range(of: "/blob/") {
            comps.path.replaceSubrange(r, with: "/resolve/")
        }
        guard let url = comps.url else { throw AddError.notHTTPS }

        let size = try await Self.probe(url)
        if size > 0, let free = Self.freeBytes(), free < size + 50_000_000 {
            throw AddError.noSpace(size)
        }

        let name = url.deletingPathExtension().lastPathComponent
        let entry = CustomVoiceModel(id: "u-\(UUID().uuidString.prefix(8))",
                                     name: name.isEmpty ? L("Modelo próprio") : name,
                                     urlString: url.absoluteString,
                                     bytes: size)
        CustomModels.add(entry)
        refresh()
        if let m = entry.model { download(m) }
    }

    /// HEAD for status + size. Servers that reject HEAD still get a chance:
    /// an unknown size only means we skip the free-space check.
    private static func probe(_ url: URL) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return 0 }
            if http.statusCode == 405 || http.statusCode == 501 { return 0 }   // HEAD unsupported
            guard (200..<300).contains(http.statusCode) else {
                throw AddError.unreachable("HTTP \(http.statusCode)")
            }
            return max(0, http.expectedContentLength)
        } catch let e as AddError {
            throw e
        } catch {
            throw AddError.unreachable(OWFailure.msg(error))
        }
    }

    private static func freeBytes() -> Int64? {
        let v = try? modelsDir().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// whisper.cpp refuses anything whose first four bytes aren't its magic
    /// (`whisper.cpp:811`, `magic != 0x67676d6c`). Checking here means a wrong
    /// link — an HTML error page, a GGUF, an ONNX file — is caught and deleted
    /// at download time instead of surfacing as a failed transcription later.
    nonisolated static func isWhisperGGML(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        let magic = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return UInt32(littleEndian: magic) == 0x6767_6d6c
    }

    // MARK: - CoreML encoder

    func downloadCoreML(_ model: VoiceModel) {
        let key = "ml:\(model.id)"
        guard tasks[key] == nil, !hasCoreML(model),
              let url = VoiceCatalog.coreMLZipURL(forID: model.id) else { return }
        error = nil
        let zipBytes = VoiceCatalog.coreMLZipBytes(forID: model.id)
        // The zip and the unpacked encoder coexist for a moment.
        if let free = Self.freeBytes(), zipBytes > 0, free < zipBytes * 2 + 50_000_000 {
            error = AddError.noSpace(zipBytes * 2).errorDescription
            return
        }
        let resuming = resumeData.removeValue(forKey: key)
        DiagnosticsStore.shared.event("coreml.download.start", ["model": model.id, "bytes": String(zipBytes),
                                                                "resume": resuming == nil ? "0" : "1"])
        progress[key] = 0
        Self.progressGate.withLock { $0[key] = nil }
        let task = resuming.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    func cancelCoreML(_ model: VoiceModel) {
        let key = "ml:\(model.id)"
        tasks[key]?.cancel(); tasks[key] = nil; progress[key] = nil
        dropResumeData(key)
    }

    func deleteCoreML(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: coreMLFolderURL(model))
        coreMLInstalled.remove(model.id)
    }

    /// Models plus their Core ML encoders (the encoders used to be left out,
    /// under-reporting by up to 1.2 GB per turbo).
    func totalInstalledBytes() -> Int64 {
        VoiceCatalog.all.filter { installed.contains($0.id) }.reduce(0) { $0 + $1.bytes }
            + VoiceCatalog.all.filter { coreMLInstalled.contains($0.id) }.reduce(0) { $0 + VoiceCatalog.coreMLZipBytes(forID: $1.id) }
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite total: Int64) {
        guard let id = downloadTask.taskDescription, total > 0 else { return }
        let p = Double(totalBytesWritten) / Double(total)
        let now = ProcessInfo.processInfo.systemUptime
        let publish = Self.progressGate.withLock { last -> Bool in
            guard Self.shouldPublish(previous: last[id], progress: p, now: now) else { return false }
            last[id] = (p, now)
            return true
        }
        if publish { Task { @MainActor in self.progress[id] = p } }
    }

    /// Last progress handed to the UI per download, and when.
    private nonisolated static let progressGate = OSAllocatedUnfairLock(initialState: [String: (Double, TimeInterval)]())

    /// Whether a new progress value is worth a redraw. Every chunk used to be
    /// published — hundreds per second on a fast link — and each one redrew the
    /// whole Ajustes › Voz form: menus closed under the finger and a tap landed
    /// on the row after it had moved (report on build 28: menus "glitch" during
    /// a download, and a tap meant for ⚡ deleted the model). Now: whole percent
    /// steps, at most four a second, and always the first and the last.
    nonisolated static func shouldPublish(previous: (Double, TimeInterval)?, progress: Double, now: TimeInterval) -> Bool {
        guard let (lastP, lastAt) = previous else { return true }
        if progress >= 1 { return true }
        // Whole percents, not a difference of doubles: 0.11 - 0.10 is
        // 0.0099999…, which held back every exact 1 % step.
        return Int(progress * 100) > Int(lastP * 100) && now - lastAt >= 0.25
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }

        if id.hasPrefix("ml:") {
            let modelID = String(id.dropFirst(3))
            guard let model = VoiceCatalog.all.first(where: { $0.id == modelID }) else { return }
            DiagnosticsStore.shared.beginSpan("coreml.unpack", ["model": model.id, "freeMB": MemoryBudget.mb(MemoryBudget.freeDiskBytes)])
            let ok = Self.unpackCoreML(zip: location, id: model.id, filename: model.filename)
            if ok { DiagnosticsStore.shared.endSpan("coreml.unpack") } else { DiagnosticsStore.shared.failSpan("coreml.unpack", "unzip") }
            Task { @MainActor in
                self.tasks[id] = nil; self.progress[id] = nil
                if ok { self.coreMLInstalled.insert(modelID) }
                else { self.error = L("Falha ao descompactar o modelo Core ML.") }
            }
            return
        }

        guard let model = VoiceCatalog.all.first(where: { $0.id == id }) else { return }

        // Validate BEFORE installing. A CDN error page or a wrong-format file
        // arrives as a perfectly successful 200; without this it lands in place
        // and only fails later, when the user tries to dictate.
        guard Self.isWhisperGGML(at: location) else {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in
                self.tasks[id] = nil; self.progress[id] = nil
                if model.isCustom { CustomModels.remove(id: id); self.refresh() }
                self.error = AddError.notAWhisperModel.errorDescription
            }
            return
        }

        let dest = Self.modelsDir().appendingPathComponent("\(model.id)-\(model.filename)")
        try? FileManager.default.removeItem(at: dest)
        let moved = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        Task { @MainActor in
            self.tasks[id] = nil; self.progress[id] = nil
            if moved { self.installed.insert(id) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        guard let id = task.taskDescription else { return }
        let resume = (err as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Self.progressGate.withLock { $0[id] = nil }
        Task { @MainActor in
            self.tasks[id] = nil; self.progress[id] = nil
            guard let err, (err as? URLError)?.code != .cancelled else { return }
            if let resume { self.resumeData[id] = resume }
            DiagnosticsStore.shared.event("download.failed", ["id": id, "resumable": resume == nil ? "0" : "1"])
            self.error = OWFailure.msg(err)
        }
    }

    /// Unzips the CoreML zip and moves the inner `.mlmodelc` folder to the path
    /// whisper.cpp derives from the .bin (`…-encoder.mlmodelc`).
    private nonisolated static func unpackCoreML(zip location: URL, id: String, filename: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.unzipItem(at: location, to: tmp)
        } catch { return false }

        // Find the .mlmodelc folder (top level or nested).
        var found: URL?
        if let en = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "mlmodelc" { found = u; break }
        }
        guard let src = found else { return false }
        let dest = modelsDir().appendingPathComponent(coreMLFolderName(id: id, filename: filename))
        try? fm.removeItem(at: dest)
        return (try? fm.moveItem(at: src, to: dest)) != nil
    }
}
