import Foundation

/// A bug report is the only thing that ever leaves the device, and only by the
/// user's hand: composed in their own mail app, with the last hour of
/// diagnostics attached, after a screen that says exactly what goes. Nothing
/// identifies the install from one report to the next, so the App Store label
/// stays "Data Not Collected" (Apple's optional-disclosure rule for
/// user-initiated, infrequent, visible submissions) and the privacy manifest
/// declares no collected data.
public enum BugReport {
    /// Where reports land: the owner's support address.
    public static let recipient = "joaozao@macrozao.online"
    /// The name that opens the subject line and the attachment.
    public static let appName = "OpenWebUI"
    /// How far back the attachment looks.
    public static let window: TimeInterval = 60 * 60
    /// The attachment is never emptier than this, even if the last hour was quiet.
    public static let minimumEvents = 50

    public struct Package: Equatable {
        public var subject: String
        public var body: String
        public var filename: String
        public var json: Data
    }

    public static func make(description: String, store: DiagnosticsStore = .shared, now: Date = Date()) -> Package {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let all = store.recentEvents(limit: 5000)
        let cutoff = now.timeIntervalSince1970 - window
        var events = all.filter { $0.ts >= cutoff }
        if events.count < minimumEvents { events = Array(all.suffix(minimumEvents)) }
        let death = store.lastSuspectedDeath()
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let filename = "\(appName.lowercased())-bug-\(stamp.string(from: now)).json"

        let env: [String: Any] = [
            "report": [
                "id": UUID().uuidString.lowercased(),
                "at": ISO8601DateFormatter().string(from: now),
                "description": desc,
                "windowSeconds": Int(window),
            ] as [String: Any],
            "app": DiagnosticsStore.appID,
            "version": version,
            "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": deviceModel,
            "locale": Locale.current.identifier,
            "physMB": MemoryBudget.mb(MemoryBudget.physicalBytes),
            "availMB": MemoryBudget.mb(MemoryBudget.availableBytes),
            "freeDiskMB": MemoryBudget.mb(MemoryBudget.freeDiskBytes),
            "lastAbnormalExit": death.map { ["name": $0.name, "ts": $0.ts, "props": $0.props] as [String: Any] } ?? NSNull(),
            "openSpans": store.openSpans(),
            "events": events.map { ["name": $0.name, "ts": $0.ts, "props": $0.props] as [String: Any] },
            "engineLog": store.engineLogTail(200),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: env, options: [.prettyPrinted, .sortedKeys])) ?? Data()

        let subject = "Bug report \(appName) \(version) (\(build)) · \(osLabel) · \(deviceModel)"
        var counts: [String: Int] = [:]
        for e in events { counts[e.name, default: 0] += 1 }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        var lines: [String] = []
        if !desc.isEmpty { lines.append(desc); lines.append("") }
        lines.append("—")
        lines.append("\(appName) \(version) (\(build)) · \(osLabel) · \(deviceModel) · \(Locale.current.identifier)")
        lines.append(L("Memória disponível: %@ · Física: %@ · Disco livre: %@",
                       MemoryBudget.human(MemoryBudget.availableBytes),
                       MemoryBudget.human(MemoryBudget.physicalBytes),
                       MemoryBudget.human(MemoryBudget.freeDiskBytes)))
        let deathText = death.map { $0.explanation + " (" + $0.date.formatted(date: .abbreviated, time: .shortened) + ")" }
        lines.append(L("Último encerramento anormal: %@", deathText ?? L("Nenhum registro.")))
        lines.append(L("Eventos anexados: %@", top.isEmpty ? "\(events.count)" : "\(events.count) (\(top))"))
        lines.append(L("Anexo: %@", filename))
        return Package(subject: subject, body: lines.joined(separator: "\n"), filename: filename, json: json)
    }

    /// "iOS 27.0" / "macOS 27.0" — the long form with the build goes in the JSON.
    public static var osLabel: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let n = v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #if os(macOS)
        return "macOS \(n)"
        #else
        return "iOS \(n)"
        #endif
    }

    /// "iPhone16,2" on iOS; "Mac15,6" on the Mac (utsname says only "arm64" there).
    public static var deviceModel: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
        #else
        var sys = utsname(); uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        #endif
    }
}

public extension DiagEvent {
    /// The sentence the owner needed to see instead of nothing: what a
    /// `death.suspected` / `session.abnormal_end` event means in words (the
    /// Diagnostics screen and the "last abnormal exit" line of a bug report).
    var explanation: String {
        let span = props["span"] ?? ""
        let model = props["model"] ?? "?"
        let avail = props["availMB"].map { $0 + " MB" } ?? "?"
        switch span {
        case "stt.load":
            return L("O app foi encerrado pelo sistema enquanto carregava o modelo %@ (havia %@ disponíveis). Provável falta de memória.", model, avail)
        case "stt.decode":
            return L("O app foi encerrado durante a transcrição com o modelo %@.", model)
        case "coreml.unpack":
            return L("O app foi encerrado enquanto descompactava o encoder Core ML de %@.", model)
        case "":
            return L("O app não foi encerrado normalmente na última vez (sem operação de voz em andamento).")
        default:
            return L("O app foi encerrado durante “%@”.", span)
        }
    }
}
