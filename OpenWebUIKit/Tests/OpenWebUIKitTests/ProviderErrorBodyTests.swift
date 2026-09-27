import XCTest
@testable import OpenWebUIKit

/// Open WebUI passes an upstream provider's refusal through untouched, so the
/// body a request fails with is whatever shape *that provider* writes.
///
/// Google's OpenAI-compatible endpoint writes it as a JSON **array** holding an
/// `error` object. Both readers only knew `{"detail": "…"}`, `{"message": "…"}`
/// and a string `error`, so a Gemini or Gemma refusal came out either as raw
/// JSON on the screen or — past 300 characters, which Google's messages usually
/// are — as the generic "Falha ao iniciar o stream", with the actual reason
/// ("API key not valid", "Developer instruction is not enabled for
/// models/gemma-3-27b-it") thrown away.
final class ProviderErrorBodyTests: XCTestCase {

    private let googleArray = #"""
    [{
      "error": {
        "code": 400,
        "message": "Developer instruction is not enabled for models/gemma-3-27b-it",
        "status": "INVALID_ARGUMENT"
      }
    }]
    """#

    private let googleKey = #"""
    [{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", "domain": "googleapis.com", "metadata": {"service": "generativelanguage.googleapis.com"}}, {"@type": "type.googleapis.com/google.rpc.LocalizedMessage", "locale": "en-US", "message": "API key not valid. Please pass a valid API key."}]}}]
    """#

    func testGoogleArrayRefusalIsReadOnTheStreamPath() {
        XCTAssertEqual(ChatCompletionsClient.extractError(googleArray),
                       "Developer instruction is not enabled for models/gemma-3-27b-it")
    }

    func testALongGoogleRefusalIsNotDroppedForBeingLong() {
        XCTAssertGreaterThan(googleKey.count, 300)
        XCTAssertEqual(ChatCompletionsClient.extractError(googleKey),
                       "API key not valid. Please pass a valid API key.")
    }

    func testOpenAIShapedErrorObject() {
        // OpenAI, OpenRouter, Groq: {"error": {"message": …}} — an object, not a string.
        XCTAssertEqual(ChatCompletionsClient.extractError(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#),
                       "Incorrect API key provided")
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"error":{"message":"quota"}}"#.utf8)), "quota")
    }

    func testGoogleArrayRefusalIsReadOnThePlainRequestPath() {
        // /audio/speech, /images/generations and the rest go through `detail(from:)`.
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(googleKey.utf8)),
                       "API key not valid. Please pass a valid API key.")
    }

    func testOpenWebUIDetailStillWins() {
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"detail":"Model not found"}"#.utf8)), "Model not found")
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"detail":{"error":{"message":"nested"}}}"#.utf8)), "nested")
    }
}
