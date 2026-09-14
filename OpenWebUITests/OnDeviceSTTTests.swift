import XCTest
@testable import OpenWebUI

/// The pure rules around the on-device engine: the Core ML folder name
/// whisper.cpp derives for a quantized model, and the memory gate.
final class OnDeviceSTTTests: XCTestCase {
    func testDownloadManagerUsesTheSameNameAndRemembersTheLegacyOne() {
        XCTAssertEqual(ModelDownloadManager.coreMLFolderName(id: "w-turbo-q5", filename: "ggml-large-v3-turbo-q5_0.bin"),
                       "w-turbo-q5-ggml-large-v3-turbo-encoder.mlmodelc")
        XCTAssertEqual(ModelDownloadManager.legacyCoreMLFolderName(id: "w-turbo-q5", filename: "ggml-large-v3-turbo-q5_0.bin"),
                       "w-turbo-q5-ggml-large-v3-turbo-q5_0-encoder.mlmodelc")
        // Unquantized models were already right, so legacy == current there.
        XCTAssertEqual(ModelDownloadManager.coreMLFolderName(id: "w-base", filename: "ggml-base.bin"),
                       ModelDownloadManager.legacyCoreMLFolderName(id: "w-base", filename: "ggml-base.bin"))
    }

    func testMemoryRequiredCountsTheCoreMLEncoderOnTop() {
        let turbo = VoiceModel(id: "w-turbo", name: "t", task: .stt, lang: .universal, bytes: 1_620_000_000, url: URL(string: "https://huggingface.co/a/b/resolve/main/c.bin")!)
        let bare = STTRunner.memoryRequired(for: turbo, coreMLBytes: 0)
        let withML = STTRunner.memoryRequired(for: turbo, coreMLBytes: 1_173_000_000)
        XCTAssertGreaterThan(bare, turbo.bytes)
        XCTAssertEqual(withML - bare, 1_173_000_000)
        #if os(macOS)
        XCTAssertNil(STTRunner.fits(turbo, coreMLBytes: 0), "no per-process limit is exposed on macOS")
        #endif
    }
}
