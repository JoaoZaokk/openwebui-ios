import SwiftUI
import OpenWebUIKit

/// How each kind of model is named and drawn wherever the app lists them.
extension OWModelKind {
    var title: String {
        switch self {
        case .chat:          return L("Conversa")
        case .image:         return L("Imagem")
        case .video:         return L("Vídeo")
        case .speech:        return L("Voz (texto para fala)")
        case .transcription: return L("Transcrição (fala para texto)")
        case .embedding:     return L("Embeddings")
        case .realtime:      return L("Áudio em tempo real")
        case .other:         return L("Outros")
        }
    }

    var symbol: String {
        switch self {
        case .chat:          return "bubble.left.and.bubble.right"
        case .image:         return "photo"
        case .video:         return "film"
        case .speech:        return "speaker.wave.2"
        case .transcription: return "waveform"
        case .embedding:     return "point.3.connected.trianglepath.dotted"
        case .realtime:      return "dot.radiowaves.left.and.right"
        case .other:         return "square.dashed"
        }
    }
}
