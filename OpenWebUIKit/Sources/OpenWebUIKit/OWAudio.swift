import Foundation

/// A voice exposed by the server's TTS engine (OpenAI, ElevenLabs, local, …).
public struct OWVoice: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            id = s; name = s; return
        }
        let c = try decoder.container(keyedBy: K.self)
        let vid = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .voice_id))
            ?? (try? c.decode(String.self, forKey: .name)) ?? UUID().uuidString
        id = vid
        name = (try? c.decode(String.self, forKey: .name)) ?? vid
    }
    enum K: String, CodingKey { case id, voice_id, name }
}

extension OpenWebUIClient {
    /// POST /api/v1/audio/speech — OpenAI-compatible TTS. Returns the synthesized
    /// audio bytes (mp3) from the server's configured engine. Empty `voice`/`model`
    /// are omitted so the server can fall back to its own defaults.
    public func speech(text: String, voice: String = "", model: String = "") async throws -> Data {
        var body: [String: Any] = ["input": text]
        if !model.isEmpty { body["model"] = model }
        if !voice.isEmpty { body["voice"] = voice }
        var req = request("/api/v1/audio/speech", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    /// POST /api/v1/audio/transcriptions — server-side STT (Whisper). Uploads the
    /// audio (multipart) and returns the recognized text.
    public func transcribe(audio: Data, filename: String = "speech.wav",
                           mime: String = "audio/wav") async throws -> String {
        var req = request("/api/v1/audio/transcriptions", method: "POST")
        let form = OWMultipart()
        form.appendFile(name: "file", filename: filename, mime: mime, fileData: audio)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized
        struct R: Decodable { var text: String }
        return try decode(R.self, try await send(req)).text
    }

    /// GET /api/v1/audio/voices — voices available for the server's TTS engine.
    /// Best-effort: returns `[]` if the server doesn't expose the endpoint.
    public func audioVoices() async -> [OWVoice] {
        guard let data = try? await send(request("/api/v1/audio/voices")) else { return [] }
        if let arr = try? JSONDecoder().decode([OWVoice].self, from: data) { return arr }
        struct Wrap: Decodable { var voices: [OWVoice] }
        if let w = try? JSONDecoder().decode(Wrap.self, from: data) { return w.voices }
        return []
    }
}
