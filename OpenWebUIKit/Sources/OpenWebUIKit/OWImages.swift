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
        decodeList(OWNamedItem.self, try await send(request("/api/v1/images/models")))
    }

    /// POST /api/v1/images/generations → server image paths (need auth to fetch).
    public func generateImages(_ body: OWImageRequest) async throws -> [String] {
        var req = try jsonRequest("/api/v1/images/generations", method: "POST", body: body)
        req.timeoutInterval = 600   // generation can be slow
        let data = try await send(req)
        return decodeList(OWGeneratedImage.self, data).map(\.url)
    }

    /// Fetches an image at a (possibly relative) server path WITH the Bearer header.
    /// Used for generated images and reloaded chat images (`/api/v1/files/{id}/content`),
    /// which `AsyncImage` can't load because it doesn't send auth.
    public func imageData(path: String) async -> Data? {
        if path.hasPrefix("data:") { return nil }   // data URLs decode locally, not here
        var req = URLRequest(url: config.url(path))
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 60
        return try? await session.data(for: req).0
    }
}
