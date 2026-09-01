import Foundation

/// Request body for POST /api/v1/images/generations.
public struct OWImageRequest: Encodable, Sendable {
    public var prompt: String
    public var n: Int
    public var size: String?
    public var negative_prompt: String?
    public var model: String?
    public var steps: Int?   // honored by some engines; otherwise set in admin config

    public init(prompt: String, n: Int = 1, size: String? = nil,
                negativePrompt: String? = nil, model: String? = nil, steps: Int? = nil) {
        self.prompt = prompt; self.n = n; self.size = size
        self.negative_prompt = negativePrompt; self.model = model; self.steps = steps
    }
}

struct OWGeneratedImage: Decodable { var url: String }

extension OpenWebUIClient {
    /// GET /api/v1/images/models — available image models (ComfyUI etc.).
    public func imageModels() async throws -> [OWNamedItem] {
        try decodeList(OWNamedItem.self, try await send(request("/api/v1/images/models")))
    }

    /// POST /api/v1/images/generations → server image paths (need auth to fetch).
    public func generateImages(_ body: OWImageRequest) async throws -> [String] {
        var req = try jsonRequest("/api/v1/images/generations", method: "POST", body: body)
        req.timeoutInterval = 600   // generation can be slow
        let data = try await send(req, long: true)
        return try decodeList(OWGeneratedImage.self, data).map(\.url)
    }

    /// Fetches an image at a (possibly relative) server path WITH the Bearer header.
    /// Used for generated images and reloaded chat images (`/api/v1/files/{id}/content`),
    /// which `AsyncImage` can't load because it doesn't send auth.
    ///
    /// The header goes on **only** for the configured server. `path` arrives from
    /// message content — a model's output, an imported chat, a shared conversation —
    /// and `OWConfig.url` passes an absolute `http(s)://` through untouched, so
    /// attaching the token unconditionally handed the user's JWT to whatever host
    /// a message named. Off-origin images still load; they just load anonymously.
    public func imageData(path: String) async -> Data? {
        try? await fetchImage(path: path)
    }

    /// The same fetch, with the failure intact.
    ///
    /// `imageData` swallowing everything is why a picture the server refuses or no
    /// longer has showed a spinner that never stopped: a 404 body is still `Data`,
    /// so the caller could not tell "still loading" from "this will never load".
    public func fetchImage(path: String) async throws -> Data {
        if path.hasPrefix("data:") { throw OWError.decoding("data URL") }
        let url = fileReferenceURL(path)
        var req = URLRequest(url: url)
        // Only our own server gets the session. A URL in a message is server- or
        // model-supplied and can point anywhere.
        if let token, isSameOrigin(url) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        let (data, resp) = try await longSession.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        return data
    }
}

extension OpenWebUIClient {
    /// Turns whatever a message stored as an image reference into a URL that
    /// actually returns image bytes.
    ///
    /// Open WebUI has changed this shape more than once, and a message keeps the
    /// shape it was written with, so all of them stay in circulation:
    ///
    /// - `data:image/...` — decoded locally, never fetched.
    /// - an absolute `http(s)` URL — a remote image; used as-is.
    /// - `/cache/image/generations/x.png` — a path; resolved against the server.
    /// - `/api/v1/files/{id}` — the older file path. Bare, it returns the file's
    ///   **metadata JSON**, not the file, so it needs `/content`.
    /// - `{id}` — 0.11 writes just the file id (`fileItem.url = uploadedFile.id`,
    ///   MessageInput.svelte:1015) and builds the URL at render time. Resolved
    ///   against the base this became `https://server/{id}`, which answers 200
    ///   with the web app's own HTML — a "successful" fetch of something that is
    ///   not an image, and the reason an attached photo showed a broken
    ///   thumbnail instead of the picture.
    func fileReferenceURL(_ raw: String) -> URL {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw) ?? config.baseURL
        }
        // Anything that is not an absolute path is a file id, and an id is one
        // path segment. Resolving it as a path let a server-supplied reference
        // like "../../admin" aim an authenticated GET at an arbitrary route.
        if !raw.hasPrefix("/") {
            return config.url("/api/v1/files/\(encPathSegment(raw))/content")
        }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let id = Self.bareFilePathID(trimmed) {
            return config.url("/api/v1/files/\(encPathSegment(id))/content")
        }
        return config.url(raw)
    }

    /// The id in `/api/v1/files/{id}` — and nothing deeper, so `/content`,
    /// `/content/html` and `/data/content` are left alone.
    static func bareFilePathID(_ path: String) -> String? {
        let marker = "/api/v1/files/"
        guard let r = path.range(of: marker), r.lowerBound == path.startIndex
                || path[..<r.lowerBound].allSatisfy({ $0 != "?" }) else { return nil }
        let rest = path[r.upperBound...]
        guard !rest.isEmpty, !rest.contains("/"), !rest.contains("?") else { return nil }
        return String(rest)
    }
}
