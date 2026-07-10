import Foundation

/// A reference attached to a message / completion. Images use
/// {type:"image", url:"data:…"}; documents use {type:"file", id, name} and
/// trigger RAG injection in the completion (verified on the live 0.9.6 server).
public struct OWAttachment: Codable, Identifiable, Hashable, Sendable {
    public var type: String
    public var id: String?
    public var url: String?
    public var name: String?

    public init(type: String, id: String? = nil, url: String? = nil, name: String? = nil) {
        self.type = type; self.id = id; self.url = url; self.name = name
    }

    public var isImage: Bool { type == "image" }
    public var displayName: String { name ?? L("arquivo") }
}

/// A file uploaded to Open WebUI (/api/v1/files/) — documents (RAG) or images.
public struct OWFile: Decodable, Identifiable, Sendable {
    public var id: String
    public var filename: String
    public var contentType: String?
    public var size: Int?

    enum CodingKeys: String, CodingKey { case id, filename, meta }
    struct Meta: Decodable { var content_type: String?; var size: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        filename = (try? c.decode(String.self, forKey: .filename)) ?? "arquivo"
        let m = try? c.decode(Meta.self, forKey: .meta)
        contentType = m?.content_type
        size = m?.size
    }

    public var isImage: Bool { contentType?.hasPrefix("image/") ?? false }
}

extension OpenWebUIClient {
    /// Uploads a file (multipart/form-data). Returns the stored file record.
    public func uploadFile(data: Data, filename: String, mime: String) async throws -> OWFile {
        var req = request("/api/v1/files/", method: "POST")
        let form = OWMultipart()
        form.appendFile(name: "file", filename: filename, mime: mime, fileData: data)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized
        return try decode(OWFile.self, try await send(req, long: true))
    }

    /// Authenticated URL to a file's raw content (needs the Bearer header to fetch).
    public func fileContentURL(_ id: String) -> URL { config.url("/api/v1/files/\(encPath(id))/content") }

    /// POST /api/v1/retrieval/process/web — fetches + extracts a web page
    /// server-side. Returns (title, plain-text content).
    public func processWebPage(url: String) async throws -> (name: String, content: String) {
        struct Body: Encodable { var url: String }
        struct Resp: Decodable {
            struct File: Decodable {
                struct DataBox: Decodable { var content: String? }
                struct Meta: Decodable { var name: String? }
                var data: DataBox?
                var meta: Meta?
            }
            var file: File?
            var filename: String?
        }
        let req = try jsonRequest("/api/v1/retrieval/process/web", method: "POST", body: Body(url: url))
        let r = try decode(Resp.self, try await send(req))
        return (r.file?.meta?.name ?? r.filename ?? url, r.file?.data?.content ?? "")
    }
}

/// Minimal multipart/form-data builder.
final class OWMultipart {
    let boundary = "----OWUIBoundary\(UUID().uuidString)"
    private var buffer = Data()

    func appendFile(name: String, filename: String, mime: String, fileData: Data) {
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        write("Content-Type: \(mime)\r\n\r\n")
        buffer.append(fileData)
        write("\r\n")
    }

    var finalized: Data {
        var d = buffer
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    private func write(_ s: String) { buffer.append(Data(s.utf8)) }
}
