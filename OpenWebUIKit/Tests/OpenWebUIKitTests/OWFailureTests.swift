import XCTest
@testable import OpenWebUIKit

final class OWFailureTests: XCTestCase {

    func testOWErrorDescribesItself() {
        XCTAssertEqual(OWFailure.msg(OWError.http(500, nil)), L("Erro %@", "500"))
        XCTAssertEqual(OWFailure.msg(OWError.http(403, "Not allowed")), "Not allowed",
                       "server text is the server's sentence, passed through verbatim")
        XCTAssertEqual(OWFailure.msg(OWError.notAuthenticated), L("Sessão expirada. Faça login novamente."))
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
