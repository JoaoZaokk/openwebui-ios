import XCTest
@testable import OpenWebUIKit

/// The pure rules around the engine: the Core ML folder name whisper.cpp
/// derives (1.8 got it wrong for every quantized model), the encoder context
/// for short clips, and the memory gate.
final class WhisperRulesTests: XCTestCase {
    func testCoreMLEncoderPathMatchesWhisperCpp() {
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-turbo-q5-ggml-large-v3-turbo-q5_0.bin"),
                       "w-turbo-q5-ggml-large-v3-turbo-encoder.mlmodelc")
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-small-q5-ggml-small-q5_1.bin"),
                       "w-small-q5-ggml-small-encoder.mlmodelc")
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-tiny-en-ggml-tiny.en.bin"),
                       "w-tiny-en-ggml-tiny.en-encoder.mlmodelc")
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "/x/y/w-turbo-ggml-large-v3-turbo.bin"),
                       "/x/y/w-turbo-ggml-large-v3-turbo-encoder.mlmodelc")
        // Only the exact -qD_D shape is a quantization suffix.
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-medium-q5-ggml-medium-q5_0.bin"),
                       "w-medium-q5-ggml-medium-encoder.mlmodelc")
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "u-1-ggml-model-q8.bin"),
                       "u-1-ggml-model-q8-encoder.mlmodelc")
    }

    func testTheLegacyNameKeptTheQuantizationSuffix() {
        XCTAssertEqual(WhisperRules.legacyCoreMLEncoderPath(forModelAt: "w-turbo-q5-ggml-large-v3-turbo-q5_0.bin"),
                       "w-turbo-q5-ggml-large-v3-turbo-q5_0-encoder.mlmodelc")
        // Unquantized models were already right, so legacy == current there.
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-base-ggml-base.bin"),
                       WhisperRules.legacyCoreMLEncoderPath(forModelAt: "w-base-ggml-base.bin"))
        XCTAssertEqual(WhisperRules.coreMLEncoderPath(forModelAt: "w-tiny-en-ggml-tiny.en.bin"),
                       WhisperRules.legacyCoreMLEncoderPath(forModelAt: "w-tiny-en-ggml-tiny.en.bin"))
    }

    func testAudioContextFollowsTheClipWithinWhisperBounds() {
        XCTAssertEqual(WhisperRules.audioContext(forSamples: 16_000 * 3), 768)      // 3 s → the streaming floor
        XCTAssertEqual(WhisperRules.audioContext(forSamples: 16_000 * 20), 1064)    // 20 s → 1000 + 64
        XCTAssertEqual(WhisperRules.audioContext(forSamples: 16_000 * 60), 1500)    // capped at the model
    }

    func testMemoryRequiredCountsTheCoreMLEncoderOnTop() {
        let turbo: Int64 = 1_620_000_000
        let bare = WhisperRules.memoryRequired(modelBytes: turbo, coreMLBytes: 0)
        let withML = WhisperRules.memoryRequired(modelBytes: turbo, coreMLBytes: 1_173_000_000)
        XCTAssertGreaterThan(bare, turbo)
        XCTAssertEqual(withML - bare, 1_173_000_000)
        #if os(macOS)
        XCTAssertNil(MemoryBudget.availableBytes, "no per-process limit is exposed on macOS")
        XCTAssertNil(WhisperRules.fits(modelBytes: turbo, coreMLBytes: 0), "so the gate is off there")
        #endif
        XCTAssertGreaterThanOrEqual(WhisperRules.decodeThreads, 1)
        XCTAssertLessThanOrEqual(WhisperRules.decodeThreads, 4)
    }

    func testPromptOnlyForKnownLanguagesAndNeverForAuto() {
        let before = UserDefaults.standard.string(forKey: STTPrompt.key)
        UserDefaults.standard.removeObject(forKey: STTPrompt.key)
        defer { UserDefaults.standard.set(before, forKey: STTPrompt.key) }
        XCTAssertNotNil(STTPrompt.forLanguage("pt"))
        XCTAssertNotNil(STTPrompt.forLanguage("en"))
        XCTAssertNil(STTPrompt.forLanguage("ja"))
        XCTAssertNil(STTPrompt.forLanguage("auto"))
        XCTAssertTrue(STTPrompt.forLanguage("pt")!.contains("um centavo"))
        UserDefaults.standard.set("Meu prompt", forKey: STTPrompt.key)
        XCTAssertEqual(STTPrompt.forLanguage("ja"), "Meu prompt", "a custom prompt applies to every language")
    }
}
