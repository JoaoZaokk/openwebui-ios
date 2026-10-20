import Foundation

/// A function call the model asked for — from the structured `tool_calls` delta
/// or written out as text (see `OWToolCallText`).
public struct OWToolCall: Sendable, Equatable {
    public var name: String
    /// The arguments as the model wrote them: JSON when it managed that, Gemma's
    /// own `{key:<|"|>value<|"|>}` syntax or something looser when it did not.
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name; self.arguments = arguments
    }

    /// What to search for. Every model met in practice names the argument one of
    /// these, as a string or a list of strings; when none is there the caller
    /// searches for the user's own words.
    public var searchQueries: [String] {
        let keys = ["queries", "query", "q", "search_query", "search", "keywords", "question", "prompt"]
        if let obj = OWToolCallText.object(fromArguments: arguments) {
            for key in keys {
                if let s = obj[key] as? String { return Self.clean([s]) }
                if let list = obj[key] as? [Any] { return Self.clean(list.compactMap { $0 as? String }) }
            }
            // Any lone string argument — `{"text": "…"}`, `{"input": "…"}`.
            let strings = obj.values.compactMap { $0 as? String }
            if strings.count == 1 { return Self.clean(strings) }
            return []
        }
        // Not parseable at all: the quoted strings in it, if any.
        return Self.clean(OWToolCallText.quotedStrings(in: arguments))
    }

    private static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(3).map { $0 }
    }
}

/// The web-search function the app offers the model itself.
///
/// Open WebUI only injects its builtin `search_web` into requests that come from
/// a browser tab (`session_id`), and it only *runs* tool calls for those too
/// (`middleware.py`, 0.12.3). The app's requests carry neither, so the server
/// passes the reply through untouched: offering the tool and running the search
/// is the app's job. The search itself goes through
/// `/api/v1/retrieval/process/web/search` — the same engine the web UI uses.
public enum OWWebSearchTool {
    public static let name = "search_web"

    static let spec: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Search the public web. Use it for anything current or that you are not sure about: news, sports results, prices, weather, schedules, recent releases, or facts after your training data.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query, in the user's language."],
                ],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ]
}

/// Tool calls a model wrote into its *text* instead of the structured field.
///
/// Gemma served by LM Studio does this some of the time — the server's parser
/// misses its `<|tool_call>call:search_web{…}<tool_call|>` and the call reaches
/// the client as ordinary content — and Qwen/Hermes-style templates do the same
/// with `<tool_call>{"name": …}</tool_call>`. Shown, it is a line of gibberish
/// in the chat; spoken, it is worse; saved, it becomes an example the model
/// copies on every later turn.
public enum OWToolCallText {

    static let openers = ["<|tool_call|>", "<|tool_call>", "<tool_call>", "<tool_calls>",
                          "<function_call>", "[TOOL_CALLS]"]
    static let closers = ["<|/tool_call|>", "<tool_call|>", "</tool_call>", "</tool_calls>",
                          "</function_call>"]

    /// `text` without any tool-call block in it (fenced code is left alone).
    /// For history: a reply saved before this existed still carries one.
    public static func stripped(_ text: String) -> String {
        guard mayContainCall(text) else { return text }
        var out = ""
        for (i, part) in text.components(separatedBy: "```").enumerated() {
            if i > 0 { out += "```" }
            if i % 2 == 1 { out += part; continue }
            var filter = OWToolCallFilter()
            var clean = filter.feed(part)
            clean += filter.finish()
            out += clean
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap pre-check, so ordinary text never runs through the filter.
    static func mayContainCall(_ text: String) -> Bool {
        if openers.contains(where: { text.contains($0) }) { return true }
        return untaggedCallStart(text.drop(while: \.isWhitespace)) != nil
    }

    /// `call:name{` at the very start of a reply: Gemma's call with the special
    /// tokens around it dropped by the server's detokenizer.
    static func untaggedCallStart(_ text: Substring) -> String? {
        guard text.hasPrefix("call:") else { return nil }
        let rest = text.dropFirst(5)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        guard !name.isEmpty, rest.dropFirst(name.count).first == "{" else { return nil }
        return String(name)
    }

    /// Parses the inside of one block. Empty when it holds no recognisable call.
    static func parse(_ body: String) -> [OWToolCall] {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") {
            if let json = try? JSONSerialization.jsonObject(with: Data(t.utf8)) {
                let items = (json as? [Any]) ?? [json]
                let calls = items.compactMap { item -> OWToolCall? in
                    guard let o = item as? [String: Any] else { return nil }
                    let fn = (o["function"] as? [String: Any]) ?? o
                    guard let name = fn["name"] as? String else { return nil }
                    let args = fn["arguments"] ?? fn["parameters"] ?? [String: Any]()
                    return OWToolCall(name: name, arguments: jsonText(args))
                }
                if !calls.isEmpty { return calls }
            }
        }
        // Gemma: `call:name{args}`; Mistral after [TOOL_CALLS]: `name[ARGS]{args}`;
        // or a bare `name{args}` / `name(args)`.
        var rest = Substring(t)
        if rest.hasPrefix("call:") { rest = rest.dropFirst(5) }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        guard !name.isEmpty else { return [] }
        var args = rest.dropFirst(name.count)
        if args.hasPrefix("[ARGS]") { args = args.dropFirst(6) }
        guard let first = args.first, first == "{" || first == "(" else { return [] }
        return [OWToolCall(name: String(name), arguments: String(args))]
    }

    /// The arguments as a dictionary, from JSON or from Gemma's syntax
    /// (`{query:<|"|>x<|"|>}`, unquoted keys).
    static func object(fromArguments raw: String) -> [String: Any]? {
        if let o = completeObject(raw) { return o }
        // A reply cut off mid-call (the stream ended, or the model stopped):
        // close what it left open and read what is there.
        for tail in ["\"}", "}", "\"]}", "]}"] {
            if let o = completeObject(raw.trimmingCharacters(in: .whitespacesAndNewlines) + tail) { return o }
        }
        return nil
    }

    private static func completeObject(_ raw: String) -> [String: Any]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = jsonObject(s) { return o }
        s = s.replacingOccurrences(of: "<|\"|>", with: "\"")
        if let o = jsonObject(s) { return o }
        // Quote bare keys: `{query: "x", count: 3}` → `{"query": "x", "count": 3}`.
        if let re = try? NSRegularExpression(pattern: #"([\{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: "$1\"$2\":")
        }
        if let o = jsonObject(s) { return o }
        // `{query:flamengo resultado}` — one bare key with an unquoted value.
        if let re = try? NSRegularExpression(pattern: #"^\{\s*"?([A-Za-z_][A-Za-z0-9_]*)"?\s*:\s*([^"\[\{][^}]*)\}$"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let k = Range(m.range(at: 1), in: s), let v = Range(m.range(at: 2), in: s) {
            return [String(s[k]): s[v].trimmingCharacters(in: .whitespaces)]
        }
        return nil
    }

    static func quotedStrings(in raw: String) -> [String] {
        let s = raw.replacingOccurrences(of: "<|\"|>", with: "\"")
        guard let re = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }.filter { $0.contains(" ") || $0.count > 3 }
    }

    private static func jsonObject(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    private static func jsonText(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Streaming side of `OWToolCallText`: feed it the reply as it arrives and it
/// hands back only what is safe to show and speak, holding back anything that
/// could still turn out to be the start of a tool call.
public struct OWToolCallFilter: Sendable {
    public private(set) var calls: [OWToolCall] = []
    private var buffer = ""
    private var callBody = ""
    private var inCall = false
    /// The untagged form ends when its braces balance, not on a closing tag.
    private var untagged = false
    private var emittedAny = false

    public init() {}

    /// The part of everything fed so far that can be shown.
    public mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while true {
            if inCall {
                if untagged {
                    guard let end = Self.balancedEnd(buffer) else { return finishOut(out) }
                    callBody = String(buffer[..<end])
                    buffer = String(buffer[end...])
                    closeCall()
                    continue
                }
                if let (range, _) = Self.firstMatch(of: OWToolCallText.closers, in: buffer) {
                    callBody += buffer[..<range.lowerBound]
                    buffer = String(buffer[range.upperBound...])
                    closeCall()
                    continue
                }
                return finishOut(out)
            }
            // Gemma with its special tokens dropped: a reply that *starts* with
            // `call:name{`. Only at the very start — anywhere else it is prose.
            if !emittedAny && out.isEmpty {
                let lead = buffer.drop(while: \.isWhitespace)
                if OWToolCallText.untaggedCallStart(lead) != nil {
                    buffer = String(lead); inCall = true; untagged = true; callBody = ""
                    continue
                }
                if Self.couldStillBeUntaggedCall(lead) { return "" }
            }
            if let (range, _) = Self.firstMatch(of: OWToolCallText.openers, in: buffer) {
                out += buffer[..<range.lowerBound]
                buffer = String(buffer[range.upperBound...])
                inCall = true; untagged = false; callBody = ""
                continue
            }
            // Keep back a tail that is the beginning of an opener.
            let keep = Self.partialOpenerTail(buffer)
            out += buffer.dropLast(keep)
            buffer = String(buffer.suffix(keep))
            return finishOut(out)
        }
    }

    /// End of the reply: whatever was held back. An unclosed call is still a call.
    public mutating func finish() -> String {
        if inCall {
            callBody += buffer
            buffer = ""
            closeCall()
            return ""
        }
        let rest = buffer
        buffer = ""
        return finishOut(rest)
    }

    private mutating func finishOut(_ out: String) -> String {
        if !out.isEmpty { emittedAny = true }
        return out
    }

    private mutating func closeCall() {
        let parsed = OWToolCallText.parse(callBody)
        // Text between the tags that is not a call at all is still the model's
        // scaffolding, never something for the user — dropped either way, but
        // only a real call asks for a search.
        calls += parsed
        callBody = ""; inCall = false; untagged = false
    }

    /// `lead` is empty, a prefix of `call:`, or `call:` plus a name still
    /// waiting for its `{` — not yet decidable.
    private static func couldStillBeUntaggedCall(_ lead: Substring) -> Bool {
        if lead.isEmpty { return true }
        if lead.count < 5 { return "call:".hasPrefix(lead) }
        guard lead.hasPrefix("call:") else { return false }
        let name = lead.dropFirst(5)
        return name.count < 64 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static func firstMatch(of needles: [String], in s: String) -> (Range<String.Index>, String)? {
        var best: (Range<String.Index>, String)?
        for n in needles {
            if let r = s.range(of: n), best == nil || r.lowerBound < best!.0.lowerBound
                || (r.lowerBound == best!.0.lowerBound && n.count > best!.1.count) {
                best = (r, n)
            }
        }
        return best
    }

    private static func partialOpenerTail(_ s: String) -> Int {
        let maxLen = OWToolCallText.openers.map(\.count).max() ?? 0
        for len in stride(from: min(maxLen - 1, s.count), through: 1, by: -1) {
            let tail = s.suffix(len)
            if OWToolCallText.openers.contains(where: { $0.hasPrefix(tail) }) { return len }
        }
        return 0
    }

    /// Index just past the `}` that balances the first `{`, skipping strings.
    private static func balancedEnd(_ s: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return s.index(after: i) }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
