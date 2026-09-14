import Foundation

/// The pure rules around the on-device whisper.cpp engine, kept out of the
/// app so they run under `swift test`: the Core ML folder name whisper.cpp
/// derives (the 1.8 app got it wrong for every quantized model), the encoder
/// context for short clips, the memory gate, and the thread count.
public enum WhisperRules {
    /// The path whisper.cpp itself derives for the Core ML encoder: drop the
    /// extension, drop a trailing `-qD_D` quantization suffix, add
    /// `-encoder.mlmodelc` (src/whisper.cpp, `whisper_get_coreml_path_encoder`).
    public static func coreMLEncoderPath(forModelAt path: String) -> String {
        var p = path
        if let dot = p.lastIndex(of: "."), !p[dot...].contains("/") { p = String(p[..<dot]) }
        if let dash = p.lastIndex(of: "-") {
            let sub = p[dash...]
            if sub.count == 5, sub[sub.index(after: dash)] == "q", sub[sub.index(dash, offsetBy: 3)] == "_" {
                p = String(p[..<dash])
            }
        }
        return p + "-encoder.mlmodelc"
    }

    /// What 1.8 wrote: only `.bin` dropped, the quantization suffix kept — so
    /// `…-q5_0-encoder.mlmodelc` sat next to a model whisper.cpp opened as
    /// `…-encoder.mlmodelc`, failed quietly (ALLOW_FALLBACK) and ran the
    /// whole encoder off the Neural Engine. The download manager renames
    /// these into place once.
    public static func legacyCoreMLEncoderPath(forModelAt path: String) -> String {
        let stem = path.hasSuffix(".bin") ? String(path.dropLast(4)) : path
        return stem + "-encoder.mlmodelc"
    }

    /// Encoder context for a clip: 320 samples per unit at 16 kHz, floored at
    /// whisper.cpp's own streaming default (768) so short dictations do not pay
    /// for a full 30 s window, capped at the model's 1500. Only valid without
    /// a Core ML encoder, whose shape is a fixed 30 s.
    public static func audioContext(forSamples n: Int) -> Int32 {
        Int32(min(1500, max(768, n / 320 + 64)))
    }

    /// Rough resident cost of a model: ggml weights are read whole (no mmap)
    /// plus compute buffers and KV caches; the Core ML encoder adds its own
    /// weights on top (whisper.cpp keeps the ggml encoder too); 300 MB is the
    /// rest of the process.
    public static func memoryRequired(modelBytes: Int64, coreMLBytes: Int64) -> Int64 {
        Int64(Double(modelBytes) * 1.3) + coreMLBytes + 300_000_000
    }

    /// nil = unknown (macOS), otherwise whether a model of that size fits
    /// under the jetsam line right now.
    public static func fits(modelBytes: Int64, coreMLBytes: Int64) -> Bool? {
        guard let avail = MemoryBudget.availableBytes else { return nil }
        return memoryRequired(modelBytes: modelBytes, coreMLBytes: coreMLBytes) <= avail
    }

    /// Thread count. whisper.cpp's own default is min(4, cores): on big.LITTLE
    /// phones every extra thread lands on an efficiency core and, because ggml
    /// joins all threads per op, drags each op down to that core's speed.
    public static var decodeThreads: Int32 {
        Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    }
}

/// The Whisper language codes that get a style prompt. Advisory only: it nudges
/// the decoder to write numbers in words ("um centavo", not "1/100") and to
/// use the language's punctuation, it does not force anything. Never applied
/// when the language is "auto".
public enum STTPrompt {
    /// A custom prompt in UserDefaults overrides the built-in ones (no UI yet).
    public static let key = "voice.stt.prompt"

    public static func forLanguage(_ code: String) -> String? {
        if let custom = UserDefaults.standard.string(forKey: key), !custom.isEmpty { return custom }
        switch code {
        case "pt": return "Transcrição em português do Brasil. Números por extenso: um centavo, dois reais, vinte e cinco por cento, três e meio."
        case "en": return "Transcript in English. Numbers written out in words: one cent, two dollars, twenty-five percent, three and a half."
        case "es": return "Transcripción en español. Números en palabras: un centavo, dos euros, veinticinco por ciento."
        default:   return nil
        }
    }
}
