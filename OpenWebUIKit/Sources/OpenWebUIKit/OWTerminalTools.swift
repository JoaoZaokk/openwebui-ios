import Foundation

/// One function of an Open Terminal the model may call, and where it goes.
///
/// Built from the terminal's `openapi.json` the way Open WebUI builds its own
/// (`convert_openapi_to_tool_payload` + `execute_tool_server`, utils/tools.py,
/// 0.13.3): `operationId` is the name, path and query parameters and the JSON
/// body's properties are the arguments.
public struct OWTerminalTool: Sendable, Equatable {
    public var name: String
    var method: String
    var path: String
    var pathParams: [String]
    var queryParams: [String]
    var requiredQuery: Set<String>
    /// Body properties the schema declares; nil for a composed body (every
    /// argument that is not a path/query parameter goes in).
    var bodyProps: Set<String>?
    var hasBody: Bool
    /// `{"type":"function","function":{name, description, parameters}}`.
    var spec: Data

    /// Changes nothing on the terminal. Everything else asks the user first.
    public var readOnly: Bool { Self.readOnlyNames.contains(name) }

    static let readOnlyNames: Set<String> = [
        "list_files", "read_file", "display_file", "grep_search", "glob_search", "search_files",
        "match_files", "list_processes", "get_process_status", "get_info", "read_user_terminal",
        "get_notebook_session", "browser_tabs", "browser_snapshot", "browser_screenshot", "desktop_screenshot",
    ]
}

public enum OWTerminalOpenAPI {

    /// Every function of the spec, with Open WebUI's own changes for a
    /// terminal: the working directory on `run_command`, `display_file`'s
    /// `page`/`inline`, and the user-shell pair only while a shell is open
    /// (`filter_user_terminal_tools`: the model would otherwise type into a
    /// shell nobody has open and get 404).
    public static func tools(from openapi: Data, cwd: String? = nil, userShellOpen: Bool = false) -> [OWTerminalTool] {
        guard let spec = try? JSONSerialization.jsonObject(with: openapi) as? [String: Any],
              let paths = spec["paths"] as? [String: Any] else { return [] }
        let components = spec["components"] as? [String: Any] ?? [:]
        var out: [OWTerminalTool] = []
        for (path, value) in paths.sorted(by: { $0.key < $1.key }) {
            guard let methods = value as? [String: Any] else { continue }
            let pathLevel = methods["parameters"] as? [[String: Any]] ?? []
            for method in ["get", "post", "put", "patch", "delete"] {
                guard let op = methods[method] as? [String: Any],
                      let name = op["operationId"] as? String, !name.isEmpty else { continue }
                if !userShellOpen && (name == "read_user_terminal" || name == "send_user_terminal_input") { continue }
                out.append(tool(name: name, method: method.uppercased(), path: path, op: op,
                                pathLevel: pathLevel, components: components, cwd: cwd))
            }
        }
        return out
    }

    private static func tool(name: String, method: String, path: String, op: [String: Any],
                             pathLevel: [[String: Any]], components: [String: Any], cwd: String?) -> OWTerminalTool {
        var description = (op["description"] as? String) ?? (op["summary"] as? String) ?? "No description available."
        var properties: [String: Any] = [:]
        var required: [String] = []
        var pathParams: [String] = [], queryParams: [String] = []
        var requiredQuery = Set<String>()

        // Operation-level parameters override path-level ones of the same (name, in).
        var merged: [String: [String: Any]] = [:]
        var order: [String] = []
        for p in pathLevel + (op["parameters"] as? [[String: Any]] ?? []) {
            guard let n = p["name"] as? String, !n.isEmpty else { continue }
            let key = n + "|" + ((p["in"] as? String) ?? "")
            if merged[key] == nil { order.append(key) }
            merged[key] = p
        }
        for key in order {
            let p = merged[key]!
            let n = p["name"] as! String
            let schema = resolve(p["schema"] as? [String: Any] ?? [:], components)
            var desc = (schema["description"] as? String) ?? ""
            if desc.isEmpty { desc = (p["description"] as? String) ?? "" }
            if let e = schema["enum"] as? [Any], !e.isEmpty {
                desc += ". Possible values: " + e.map { "\($0)" }.joined(separator: ", ")
            }
            // Pydantic writes `Optional[list[str]]` as `anyOf: [{array, items}, {null}]`:
            // the non-null branch is the parameter (with its `items`, which
            // OpenAI requires of an array).
            let eff = effective(schema)
            var prop: [String: Any] = ["type": (eff["type"] as? String) ?? "string", "description": desc]
            if (eff["type"] as? String) == "array" { prop["items"] = eff["items"] ?? ["type": "string"] }
            properties[n] = prop
            let isRequired = (p["required"] as? Bool) ?? false
            if isRequired { required.append(n) }
            switch p["in"] as? String {
            case "path": pathParams.append(n)
            case "query": queryParams.append(n); if isRequired { requiredQuery.insert(n) }
            default: break
            }
        }

        var bodyProps: Set<String>? = []
        var hasBody = false
        var parameters: [String: Any]? = nil
        if let rb = op["requestBody"] as? [String: Any],
           let content = rb["content"] as? [String: Any],
           let json = content["application/json"] as? [String: Any],
           let raw = json["schema"] as? [String: Any] {
            hasBody = true
            let body = resolve(raw, components)
            if ["allOf", "anyOf", "oneOf"].contains(where: { body[$0] != nil }) { bodyProps = nil }
            if let props = body["properties"] as? [String: Any], !props.isEmpty {
                for (k, v) in props { properties[k] = v }
                bodyProps = bodyProps.map { $0.union(props.keys) }
                for r in body["required"] as? [String] ?? [] where !required.contains(r) { required.append(r) }
            } else if (body["type"] as? String) == "array" {
                parameters = body
            }
        }

        if name == "run_command", let cwd, !cwd.isEmpty {
            description += "\n\nThe current working directory is: \(cwd)"
        }
        if name == "display_file" {
            // Open WebUI's builtin `display_file` replaces the terminal's: the
            // page of a PDF/DOCX/PPTX, and inline display.
            description = "Show a terminal file to the user. After display_file succeeds, do not display the same file again or emit Markdown for it."
            properties["page"] = ["type": "integer", "description": "For PDF, DOCX, and PPTX files, open the preview at this 1-based page or slide number"]
            properties["inline"] = ["type": "boolean", "description": "Show the file inline instead of opening the file viewer"]
        }

        var params = parameters ?? ["type": "object", "properties": properties, "required": required] as [String: Any]
        clean(&params)
        let fn: [String: Any] = ["name": name, "description": description, "parameters": params]
        let spec = (try? JSONSerialization.data(withJSONObject: ["type": "function", "function": fn],
                                                options: [.sortedKeys])) ?? Data()
        return OWTerminalTool(name: name, method: method, path: path, pathParams: pathParams,
                              queryParams: queryParams, requiredQuery: requiredQuery,
                              bodyProps: bodyProps, hasBody: hasBody, spec: spec)
    }

    /// `$ref` into `components/schemas`, all the way down.
    static func resolve(_ schema: [String: Any], _ components: [String: Any], seen: Set<String> = []) -> [String: Any] {
        if let ref = schema["$ref"] as? String {
            let name = ref.components(separatedBy: "/").last ?? ""
            guard !seen.contains(name),
                  let target = (components["schemas"] as? [String: Any])?[name] as? [String: Any] else { return [:] }
            return resolve(target, components, seen: seen.union([name]))
        }
        var s = schema
        if let props = s["properties"] as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in props { out[k] = resolve(v as? [String: Any] ?? [:], components, seen: seen) }
            s["properties"] = out
        }
        if let items = s["items"] as? [String: Any] { s["items"] = resolve(items, components, seen: seen) }
        for key in ["oneOf", "anyOf", "allOf"] {
            if let list = s[key] as? [[String: Any]] { s[key] = list.map { resolve($0, components, seen: seen) } }
        }
        return s
    }

    /// The schema itself, or its one non-null `anyOf` branch.
    private static func effective(_ schema: [String: Any]) -> [String: Any] {
        if schema["type"] is String { return schema }
        if let any = schema["anyOf"] as? [[String: Any]] {
            let nonNull = any.filter { ($0["type"] as? String) != "null" }
            if nonNull.count == 1 { return nonNull[0] }
        }
        return schema
    }

    /// `clean_properties` (utils/tools.py): no `null` branch, no `null` default,
    /// always a type.
    static func clean(_ schema: inout [String: Any]) {
        if let any = schema["anyOf"] as? [[String: Any]] {
            let nonNull = any.filter { ($0["type"] as? String) != "null" }
            if nonNull.count == 1 {
                for (k, v) in nonNull[0] { schema[k] = v }
                schema["anyOf"] = nil
            } else {
                schema["anyOf"] = nonNull
            }
        }
        if schema.keys.contains("default"), schema["default"] is NSNull { schema["default"] = nil }
        if schema["type"] == nil, schema["anyOf"] == nil, schema["properties"] == nil { schema["type"] = "string" }
        if var props = schema["properties"] as? [String: Any] {
            for (k, v) in props {
                guard var p = v as? [String: Any] else { continue }
                clean(&p)
                props[k] = p
            }
            schema["properties"] = props
        }
    }
}

// MARK: - A turn with a terminal

/// What one turn needs from the terminal before it starts: its functions,
/// the instructions it gives the model, and the user's AGENTS.md.
public struct OWTerminalContext: Sendable {
    public var terminal: OWTerminalServer
    /// The chat the calls belong to (`X-Session-Id`).
    public var session: String?
    public var tools: [OWTerminalTool]
    public var systemPrompt: String?
    /// `# AGENTS.md\n\n…`, from the terminal user's home.
    public var agentsMD: String?
    public var cwd: String?

    public init(terminal: OWTerminalServer, session: String?, tools: [OWTerminalTool],
                systemPrompt: String? = nil, agentsMD: String? = nil, cwd: String? = nil) {
        self.terminal = terminal; self.session = session; self.tools = tools
        self.systemPrompt = systemPrompt; self.agentsMD = agentsMD; self.cwd = cwd
    }

    public func handles(_ name: String) -> Bool { tools.contains { $0.name == name } }

    /// The messages as the server would send them with this terminal on: its
    /// prompt appended to the system message (or a new one in front), and the
    /// AGENTS.md as a user turn right before the first user turn.
    public func applied(to messages: [OWChatMessageInput]) -> [OWChatMessageInput] {
        var m = messages
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            if let first = m.first, first.role == "system" {
                m[0].text += "\n\n" + prompt
            } else {
                m.insert(OWChatMessageInput(role: "system", text: prompt), at: 0)
            }
        }
        if let agents = agentsMD, let i = m.firstIndex(where: { $0.role == "user" }) {
            m.insert(OWChatMessageInput(role: "user", text: agents), at: i)
        }
        return m
    }
}

/// What the user is asked before the model changes something on the terminal.
public struct OWTerminalApprovalRequest: Identifiable, Sendable, Equatable {
    public var id: String
    public var terminalID: String
    public var terminalName: String
    public var tool: String
    /// The command, the path, or the text that would be typed.
    public var summary: String
    /// Working directory, the content to be written, the replacement.
    public var detail: String
    /// Looks like it deletes, overwrites or escalates.
    public var dangerous: Bool
}

public enum OWTerminalApproval: Sendable, Equatable {
    case allow
    case deny
}

public typealias OWTerminalApprover = @Sendable (OWTerminalApprovalRequest) async -> OWTerminalApproval

/// The terminal for one reply: the context and who says yes.
public struct OWReplyTerminal: Sendable {
    public var context: OWTerminalContext
    public var approve: OWTerminalApprover
    public init(context: OWTerminalContext, approve: @escaping OWTerminalApprover) {
        self.context = context; self.approve = approve
    }
}

/// One terminal call, done: what goes back to the model and the card.
struct OWTerminalOutcome: Sendable {
    var modelText: String
    var card: OWToolUse
}

public extension OpenWebUIClient {

    /// Fetches what a turn with this terminal needs. Only the functions are
    /// required; the prompt, the working directory and AGENTS.md are what the
    /// server would add, and a turn goes ahead without them.
    func prepareTerminal(_ terminal: OWTerminalServer, session: String?,
                         userShellOpen: Bool = false) async throws -> OWTerminalContext {
        async let spec = terminalRequest(terminal.id, "openapi.json", session: session)
        async let prompt = terminalSystemPrompt(terminal.id, session: session)
        async let place = try? terminalPlace(terminal.id, session: session)
        let p = await place
        async let agents = terminalAgentsMD(terminal.id, home: p?.home, session: session)
        var shell = false
        if userShellOpen {
            shell = (try? await terminalRequest(terminal.id, "api/terminals/user/output", session: session)) != nil
        }
        let tools = OWTerminalOpenAPI.tools(from: try await spec, cwd: p?.cwd, userShellOpen: shell)
        guard !tools.isEmpty else { throw OWError.decoding("openapi.json") }
        return OWTerminalContext(terminal: terminal, session: session, tools: tools,
                                 systemPrompt: await prompt, agentsMD: await agents, cwd: p?.cwd)
    }

    /// `/system`, when the terminal says it has one (`features.system`).
    func terminalSystemPrompt(_ terminal: String, session: String?) async -> String? {
        guard let config = try? Self.jsonObject(try await terminalRequest(terminal, "api/config", session: session)),
              (config["features"] as? [String: Any])?["system"] as? Bool == true,
              let obj = try? Self.jsonObject(try await terminalRequest(terminal, "system", session: session)),
              let prompt = obj["prompt"] as? String, !prompt.isEmpty else { return nil }
        return prompt
    }

    /// The home's AGENTS.md, as the server injects it; nil above 32 KiB.
    func terminalAgentsMD(_ terminal: String, home: String?, session: String?) async -> String? {
        guard let home, home.hasPrefix("/"),
              let text = try? await readTerminalText(terminal, path: Self.join(home, "AGENTS.md"),
                                                     from: 1, to: 2_000, session: session),
              !text.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.content.utf8.count <= 32 * 1024 else { return nil }
        return "# AGENTS.md\n\n" + text.content
    }

    /// Runs one call the model made, asking first when it changes something.
    /// `progress` gets the card again while a long command is still going.
    internal func runTerminalTool(_ call: OWToolCall, context: OWTerminalContext, approve: OWTerminalApprover,
                                  progress: @escaping @Sendable (OWToolUse) -> Void) async throws -> OWTerminalOutcome {
        let callID = call.id ?? UUID().uuidString
        let args = call.object
        let summary = OWTerminalToolText.summary(call.name, args)
        func card(_ results: String, status: String, exit: Int? = nil) -> OWToolUse {
            var c = OWToolUse(action: call.name, query: summary, results: OWTerminalToolText.forCard(results),
                              sources: [], callID: callID)
            c.terminalID = context.terminal.id
            c.status = status
            c.exitCode = exit
            return c
        }
        guard let tool = context.tools.first(where: { $0.name == call.name }) else {
            let err = OpenWebUIClient.jsonText(["error": "Unknown terminal function \(call.name)."])
            return OWTerminalOutcome(modelText: err, card: card(err, status: "failed"))
        }

        if !tool.readOnly {
            let ask = OWTerminalApprovalRequest(
                id: callID, terminalID: context.terminal.id, terminalName: context.terminal.name,
                tool: call.name, summary: summary, detail: OWTerminalToolText.detail(call.name, args, cwd: context.cwd),
                dangerous: OWTerminalToolText.looksDangerous(call.name, args))
            progress(card("", status: "approval"))
            let answer = await approve(ask)
            try Task.checkCancellation()
            if answer == .deny {
                let text = OpenWebUIClient.jsonText(["error": "Tool call rejected by user."])
                return OWTerminalOutcome(modelText: text, card: card("", status: "denied"))
            }
        }
        progress(card("", status: "running"))

        do {
            if call.name == "run_command" {
                return try await runCommandTool(args, context: context, card: card, progress: progress)
            }
            if call.name == "get_process_status" {
                var a = args
                // One read here is at most 25 s; the model may ask again.
                if let w = OWTerminalToolText.double(a["wait"]) { a["wait"] = min(w, 25) }
                if a["tail"] == nil { a["tail"] = 250 }
                let data = try await sendTerminalTool(tool, a, context: context)
                let p = Self.process(data, command: "")
                let text = OWTerminalToolText.processForModel(p)
                return OWTerminalOutcome(modelText: text, card: card(p.output, status: p.isRunning ? "running" : "done", exit: p.exitCode))
            }
            var a = args
            if call.name == "display_file" { a["page"] = nil; a["inline"] = nil }
            if call.name == "read_file", a["start_line"] == nil, a["end_line"] == nil {
                a["start_line"] = 1; a["end_line"] = 2_000
            }
            let data = try await sendTerminalTool(tool, a, context: context)
            var text = String(data: data, encoding: .utf8) ?? ""
            if text.isEmpty && !data.isEmpty {
                text = OpenWebUIClient.jsonText(["result": "binary content, \(data.count) bytes"])
            }
            var done = card(text, status: "done")
            if call.name == "display_file" {
                done.query = args["path"] as? String ?? summary
                done.displayPage = OWTerminalToolText.int(args["page"])
                done.displayInline = (args["inline"] as? Bool) ?? false
            }
            return OWTerminalOutcome(modelText: OWTerminalToolText.forModel(text), card: done)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let why = (error as? OWError)?.errorDescription ?? error.localizedDescription
            let text = OpenWebUIClient.jsonText(["error": why])
            return OWTerminalOutcome(modelText: text, card: card(why, status: "failed"))
        }
    }

    /// `run_command` without leaving the request open for minutes: 25 s, then
    /// status reads of 15 s each, the card updated after each, up to ~85 s.
    /// What is still running then goes back to the model with its id.
    private func runCommandTool(_ args: [String: Any], context: OWTerminalContext,
                                card: (String, String, Int?) -> OWToolUse,
                                progress: @escaping @Sendable (OWToolUse) -> Void) async throws -> OWTerminalOutcome {
        let command = args["command"] as? String ?? ""
        let asked = OWTerminalToolText.double(args["wait"])
        let first = min(asked ?? 25, 25)
        let tail = OWTerminalToolText.int(args["tail"]) ?? 250
        var p = try await runTerminalCommand(context.terminal.id, command: command, cwd: args["cwd"] as? String,
                                             wait: first, tail: tail, session: context.session)
        var output = p.output
        var reads = 0
        let terminal = context.terminal.id, session = context.session
        do {
            while p.isRunning, !p.id.isEmpty, reads < 4, (asked ?? 25) > first {
                progress(card(output, "running", nil))
                reads += 1
                let more = try await terminalProcess(terminal, id: p.id, wait: 15, offset: p.nextOffset,
                                                     tail: tail, session: session)
                output += more.output
                p.status = more.status; p.exitCode = more.exitCode
                p.nextOffset = more.nextOffset; p.truncated = p.truncated || more.truncated
            }
        } catch is CancellationError {
            // The terminal keeps a command going when its request goes away
            // (open_terminal `execute` shields it): stopping the reply stops it.
            let id = p.id
            Task.detached { try? await self.killTerminalProcess(terminal, id: id, session: session) }
            throw CancellationError()
        }
        p.output = output
        let status = p.isRunning ? "running" : "done"
        return OWTerminalOutcome(modelText: OWTerminalToolText.processForModel(p),
                                 card: card(output, status, p.exitCode))
    }

    /// One function call, as `execute_tool_server` sends it: path parameters
    /// into the path, declared query parameters into the query (an empty
    /// optional one left out), the rest into the JSON body.
    internal func sendTerminalTool(_ tool: OWTerminalTool, _ args: [String: Any],
                                   context: OWTerminalContext) async throws -> Data {
        var path = tool.path
        for name in tool.pathParams {
            if let v = args[name] { path = path.replacingOccurrences(of: "{\(name)}", with: encPath(OWTerminalToolText.text(v))) }
        }
        var query: [(String, String)] = []
        for name in tool.queryParams {
            guard let v = args[name], !(v is NSNull) else { continue }
            let s = OWTerminalToolText.text(v)
            if s.isEmpty && !tool.requiredQuery.contains(name) { continue }
            if let list = v as? [Any] {
                for item in list { query.append((name, OWTerminalToolText.text(item))) }
            } else {
                query.append((name, s))
            }
        }
        var body: [String: Any]? = nil
        if tool.hasBody, !args.isEmpty {
            let declared = Set(tool.pathParams + tool.queryParams)
            if let props = tool.bodyProps, !props.isEmpty {
                body = args.filter { props.contains($0.key) || !declared.contains($0.key) }
            } else {
                body = args
            }
        }
        return try await terminalRequest(context.terminal.id, path, method: tool.method, query: query,
                                         json: body, session: context.session, long: true)
    }
}

/// How terminal calls read on the card, in the approval and to the model.
enum OWTerminalToolText {

    /// What the call is about, in a line.
    static func summary(_ name: String, _ a: [String: Any]) -> String {
        switch name {
        case "run_command": return a["command"] as? String ?? ""
        case "send_process_input", "send_user_terminal_input":
            return (a["input"] as? String) ?? (a["data"] as? String) ?? (a["text"] as? String) ?? ""
        case "kill_process", "get_process_status": return (a["process_id"] as? String) ?? ""
        case "grep_search", "glob_search", "search_files", "match_files":
            return (a["query"] as? String) ?? (a["pattern"] as? String) ?? (a["path"] as? String) ?? ""
        case "list_files": return (a["directory"] as? String) ?? (a["path"] as? String) ?? ""
        default: return (a["path"] as? String) ?? ""
        }
    }

    /// What the approval shows under the summary.
    static func detail(_ name: String, _ a: [String: Any], cwd: String?) -> String {
        switch name {
        case "run_command":
            let dir = (a["cwd"] as? String) ?? cwd ?? ""
            return dir.isEmpty ? "" : dir
        case "write_file": return String((a["content"] as? String ?? "").prefix(4_000))
        case "replace_file_content":
            if let reps = a["replacements"] as? [[String: Any]] {
                return reps.prefix(6).map { r in
                    "- " + String((r["target"] as? String ?? "").prefix(600)) + "\n+ " + String((r["replacement"] as? String ?? "").prefix(600))
                }.joined(separator: "\n\n")
            }
            let t = (a["target"] as? String) ?? ""
            let r = (a["replacement"] as? String) ?? ""
            return "- " + String(t.prefix(1_500)) + "\n+ " + String(r.prefix(1_500))
        case "kill_process": return (a["force"] as? Bool) == true ? "SIGKILL" : "SIGTERM"
        default:
            let obj = a.filter { $0.key != "path" }
            return obj.isEmpty ? "" : String(OpenWebUIClient.jsonText(obj).prefix(2_000))
        }
    }

    private static let dangerousPatterns = [
        "rm ", "rm\t", "rmdir", "sudo ", "dd ", "mkfs", "chmod -r", "chown -r", "> /dev/", "shutdown", "reboot",
        "git reset --hard", "git push --force", "git push -f", "git clean", "| sh", "|sh", "| bash", "|bash", ":(){",
        "kill -9", "killall", "truncate ", "drop table", "drop database",
    ]

    static func looksDangerous(_ name: String, _ a: [String: Any]) -> Bool {
        switch name {
        case "run_command":
            let c = (a["command"] as? String ?? "").lowercased()
            return dangerousPatterns.contains { c.contains($0) } || c.hasPrefix("rm")
        case "kill_process": return (a["force"] as? Bool) == true
        default: return false
        }
    }

    /// The model gets 16 000 characters at most: the start (what ran) and,
    /// mostly, the end (where errors and summaries are).
    static func forModel(_ s: String, head: Int = 4_000, tail: Int = 12_000) -> String {
        guard s.count > head + tail else { return s }
        let left = s.count - head - tail
        return String(s.prefix(head)) + "\n… [\(left) characters left out; read the rest with get_process_status (offset/tail) or read_file (start_line/end_line)] …\n" + String(s.suffix(tail))
    }

    /// The card keeps 4 000: it is saved with the chat on the server.
    static func forCard(_ s: String) -> String {
        guard s.count > 4_000 else { return s }
        return String(s.prefix(1_000)) + "\n…\n" + String(s.suffix(3_000))
    }

    static func processForModel(_ p: OWTerminalProcess) -> String {
        var obj: [String: Any] = ["id": p.id, "status": p.status, "next_offset": p.nextOffset,
                                  "output": forModel(p.output)]
        if let e = p.exitCode { obj["exit_code"] = e }
        if p.truncated { obj["truncated"] = true }
        if p.isRunning {
            obj["note"] = "Still running. Call get_process_status with process_id \(p.id) and offset \(p.nextOffset) to read more, send_process_input to answer it, or kill_process to stop it."
        }
        return OpenWebUIClient.jsonText(obj)
    }

    static func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
