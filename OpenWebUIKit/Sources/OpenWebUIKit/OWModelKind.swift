import Foundation

/// What a model listed on `/api/models` is for.
///
/// Open WebUI lists whatever a connection's `/models` returns. An OpenAI key or
/// — worse — a Gemini key returns the provider's whole catalogue: chat models
/// beside text-to-speech, Imagen/DALL·E, Veo/Sora, embeddings and live-audio
/// models. Only the chat ones answer `/api/chat/completions`; the others fail
/// there, every time, with a provider error. Sorting them lets the chat menu
/// offer only what can chat and still show the rest for what it is.
///
/// Judged from the id, which is the only thing every connection reports — the
/// display name of a workspace model is a nickname ("Tradutor") and says
/// nothing. Matching is by whole token, so `mattsmith/llama` is not a speech
/// model and `llava` is not an image one.
public enum OWModelKind: String, CaseIterable, Sendable {
    case chat, image, video, speech, transcription, embedding, realtime, other

    /// Only these can be sent a conversation.
    public var canChat: Bool { self == .chat }

    public static func of(id: String) -> OWModelKind {
        let lower = id.lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ words: String...) -> Bool { words.contains { tokens.contains($0) } }

        if has("realtime", "live", "lyria") || lower.contains("native-audio") || lower.contains("audio-preview") {
            return .realtime
        }
        if has("embed", "embedding", "embeddings", "rerank", "reranker", "bge")
            || tokens.contains(where: { $0.hasPrefix("embed") }) {
            return .embedding
        }
        if has("whisper", "transcribe", "stt", "asr", "parakeet") { return .transcription }
        if has("tts", "speech") { return .speech }
        if has("veo", "sora", "video", "kling", "hailuo") { return .video }
        if has("imagen", "image", "dall", "flux", "sdxl", "diffusion", "banana", "midjourney", "ideogram", "recraft") {
            return .image
        }
        if has("aqa", "moderation") { return .other }
        return .chat
    }
}

extension OWModel {
    public var kind: OWModelKind { OWModelKind.of(id: id) }
}
