import XCTest
@testable import OpenWebUIKit

/// What a model on `/api/models` is *for*.
///
/// Open WebUI lists every model a connection's `/models` returns, and a Gemini
/// key returns all of Google's: chat models next to text-to-speech, Imagen, Veo,
/// embeddings and the live-audio models. All of them landed in the one chat
/// menu, where anything but a chat model can only fail — so a Gemini key looked
/// like it "was not recognised": the list filled with names that errored.
final class ModelKindTests: XCTestCase {

    private func kind(_ id: String, _ name: String? = nil) -> OWModelKind {
        OWModel(id: id, name: name ?? id).kind
    }

    func testGoogleCatalogue() {
        // Ids as Google's OpenAI-compatible /models writes them, prefix included.
        XCTAssertEqual(kind("models/gemini-2.5-pro"), .chat)
        XCTAssertEqual(kind("models/gemini-2.5-flash"), .chat)
        XCTAssertEqual(kind("models/gemini-2.5-flash-lite"), .chat)
        XCTAssertEqual(kind("models/gemini-3-pro-preview"), .chat)
        XCTAssertEqual(kind("models/gemma-3-27b-it"), .chat)
        XCTAssertEqual(kind("models/gemma-3n-e4b-it"), .chat)
        XCTAssertEqual(kind("models/gemini-2.5-computer-use-preview-10-2025"), .chat)

        XCTAssertEqual(kind("models/gemini-2.5-flash-preview-tts"), .speech)
        XCTAssertEqual(kind("models/gemini-2.5-pro-preview-tts"), .speech)

        XCTAssertEqual(kind("models/imagen-4.0-generate-001"), .image)
        XCTAssertEqual(kind("models/imagen-4.0-ultra-generate-001"), .image)
        XCTAssertEqual(kind("models/gemini-2.5-flash-image"), .image)
        XCTAssertEqual(kind("models/gemini-2.0-flash-preview-image-generation"), .image)
        XCTAssertEqual(kind("models/nano-banana-pro-preview"), .image)

        XCTAssertEqual(kind("models/veo-3.0-generate-001"), .video)
        XCTAssertEqual(kind("models/veo-3.0-fast-generate-001"), .video)

        XCTAssertEqual(kind("models/gemini-embedding-001"), .embedding)
        XCTAssertEqual(kind("models/text-embedding-004"), .embedding)

        XCTAssertEqual(kind("models/gemini-2.5-flash-native-audio-preview-09-2025"), .realtime)
        XCTAssertEqual(kind("models/gemini-live-2.5-flash-preview"), .realtime)
        XCTAssertEqual(kind("models/lyria-realtime-exp"), .realtime)
        XCTAssertEqual(kind("models/aqa"), .other)
    }

    func testOpenAICatalogue() {
        XCTAssertEqual(kind("gpt-4o"), .chat)
        XCTAssertEqual(kind("gpt-5-mini"), .chat)
        XCTAssertEqual(kind("o3"), .chat)
        XCTAssertEqual(kind("tts-1"), .speech)
        XCTAssertEqual(kind("tts-1-hd"), .speech)
        XCTAssertEqual(kind("gpt-4o-mini-tts"), .speech)
        XCTAssertEqual(kind("whisper-1"), .transcription)
        XCTAssertEqual(kind("gpt-4o-transcribe"), .transcription)
        XCTAssertEqual(kind("gpt-4o-mini-transcribe"), .transcription)
        XCTAssertEqual(kind("dall-e-3"), .image)
        XCTAssertEqual(kind("gpt-image-1"), .image)
        XCTAssertEqual(kind("sora-2"), .video)
        XCTAssertEqual(kind("text-embedding-3-small"), .embedding)
        XCTAssertEqual(kind("omni-moderation-latest"), .other)
        XCTAssertEqual(kind("gpt-4o-realtime-preview"), .realtime)
        XCTAssertEqual(kind("gpt-4o-audio-preview"), .realtime)
    }

    func testLocalAndRouterNames() {
        XCTAssertEqual(kind("llama3.1:8b"), .chat)
        XCTAssertEqual(kind("qwen2.5-coder:32b"), .chat)
        XCTAssertEqual(kind("nomic-embed-text:latest"), .embedding)
        XCTAssertEqual(kind("bge-m3:latest"), .embedding)
        XCTAssertEqual(kind("openrouter/google/gemini-2.5-flash"), .chat)
        XCTAssertEqual(kind("black-forest-labs/flux-1.1-pro"), .image)
        // A word that merely contains "tts" or "image" is not a speech or image model.
        XCTAssertEqual(kind("mattsmith/llama-3-8b"), .chat)
        XCTAssertEqual(kind("llava:13b"), .chat)
        XCTAssertEqual(kind("qwen2.5-vl-72b-instruct"), .chat)
    }

    func testAWorkspaceModelIsJudgedByItsIdNotItsNickname() {
        // "Tradutor" is a custom model on a chat base; its name says nothing.
        XCTAssertEqual(kind("tradutor", "Tradutor"), .chat)
    }

    func testOnlyChatModelsCanBeTalkedTo() {
        XCTAssertTrue(OWModelKind.chat.canChat)
        for k in OWModelKind.allCases where k != .chat { XCTAssertFalse(k.canChat, "\(k)") }
    }
}
