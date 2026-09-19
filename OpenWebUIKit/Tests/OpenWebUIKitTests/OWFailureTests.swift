import XCTest
@testable import OpenWebUIKit

final class OWFailureTests: XCTestCase {

    func testOWErrorDescribesItself() {
        XCTAssertEqual(OWFailure.msg(OWError.http(500, nil)), L("Erro %@", "500"))
        XCTAssertEqual(OWFailure.msg(OWError.http(403, "Not allowed")), "Not allowed",
                       "server text is the server's sentence, passed through verbatim")
        XCTAssertEqual(OWFailure.msg(OWError.notAuthenticated), L("Sessão expirada. Faça login novamente."))
    }

    /// `URLError.localizedDescription` is written by Foundation in the *device's*
    /// language, so a phone set to Portuguese put "Não foi possível conectar-se
    /// ao servidor." in the error banner of an app the user had set to English —
    /// and a self-hosted client shows that banner whenever the server is asleep.
    /// The sentences the user reads have to come from our catalogue.
    func testNetworkFailuresSpeakTheAppLanguageNotTheDevicesOne() {
        XCTAssertEqual(OWFailure.msg(URLError(.notConnectedToInternet)), L("Sem conexão com a internet."))
        XCTAssertEqual(OWFailure.msg(URLError(.timedOut)), L("O servidor demorou demais para responder."))
        XCTAssertEqual(OWFailure.msg(URLError(.cannotFindHost)), L("Não encontrei esse servidor. Confira o endereço."))
        XCTAssertEqual(OWFailure.msg(URLError(.cannotConnectToHost)), L("Não consegui falar com o servidor. Ele está ligado?"))
        XCTAssertEqual(OWFailure.msg(URLError(.networkConnectionLost)), L("A conexão caiu no meio do caminho."))
        XCTAssertEqual(OWFailure.msg(URLError(.secureConnectionFailed)), L("Falha na conexão segura com o servidor."))

        // Nothing Foundation wrote reaches the user, not even for a code with no
        // sentence of its own — the number is language-neutral and says enough.
        let exotic = URLError(.dataLengthExceedsMaximum)
        XCTAssertEqual(OWFailure.msg(exotic), L("Falha de rede (%@).", "\(exotic.errorCode)"))
        XCTAssertNotEqual(OWFailure.msg(exotic), exotic.localizedDescription)
    }

    func testForeignErrorsFallBackToLocalizedDescription() {
        let e = NSError(domain: "t", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(OWFailure.msg(e), "boom")
    }

    func testBothSpellingsOfCancellation() {
        XCTAssertTrue(CancellationError().isCancellation)
        XCTAssertTrue(URLError(.cancelled).isCancellation)
        XCTAssertFalse(URLError(.timedOut).isCancellation)
        XCTAssertFalse(OWError.http(500, nil).isCancellation)
    }
}
