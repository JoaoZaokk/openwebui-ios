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
        case .http(let code, let msg): return msg ?? "Erro \(code)"
        case .notAuthenticated:        return "Sessão expirada. Faça login novamente."
        case .decoding(let m):         return "Resposta inesperada do servidor: \(m)"
        case .transport(let m):        return m
        case .notConfigured:           return "Servidor não configurado."
        }
    }
}
