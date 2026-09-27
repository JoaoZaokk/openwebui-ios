import Foundation

/// Errors surfaced by the Open WebUI client. Messages are pt-BR because they may
/// reach the UI directly.
public enum OWError: LocalizedError {
    case http(Int, String?)
    case notAuthenticated
    case decoding(String)
    case transport(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return msg ?? L("Erro %@", String(code))
        case .notAuthenticated:        return L("Sessão expirada. Faça login novamente.")
        case .decoding(let m):         return L("Resposta inesperada do servidor: %@", m)
        case .transport(let m):        return m
        case .notConfigured:           return L("Servidor não configurado.")
        }
    }
}

/// The sentence inside an error body, whichever server or provider wrote it.
///
/// Open WebUI answers its own refusals as `{"detail": …}`, but it passes an
/// upstream provider's body through untouched, so the reader has to know the
/// providers' shapes too: OpenAI-compatible hosts write `{"error": {"message": …}}`,
/// and Google's OpenAI-compatible endpoint wraps that in a top-level **array**.
/// Missing those turned every Gemini/Gemma refusal — a bad key, a model that
/// takes no system prompt — into raw JSON or a generic sentence.
enum OWErrorSentence {
    /// Nil when the body is not JSON or names no message.
    static func sentence(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return sentence(in: obj)
    }

    static func sentence(in obj: Any) -> String? {
        if let arr = obj as? [Any] {
            // Google: [{ "error": { … } }]. FastAPI validation lists are handled
            // by the caller, which knows about `loc`.
            return arr.lazy.compactMap { sentence(in: $0) }.first
        }
        if let s = obj as? String { return s.isEmpty ? nil : s }
        guard let dict = obj as? [String: Any] else { return nil }
        for key in ["detail", "message", "error"] {
            if let v = dict[key], let s = sentence(in: v) { return s }
        }
        return nil
    }
}
