import XCTest
@testable import OpenWebUI

/// The parts of the answer to the report on build 28 that run off the phone:
/// how often a download redraws the settings, and the models the engine cannot
/// load.
final class Build29ReportTests: XCTestCase {

    /// Hundreds of progress callbacks a second became hundreds of redraws of
    /// Ajustes › Voz: menus closed under the finger and a tap meant for ⚡ hit
    /// the trash. Whole percent steps, at most four a second, first and last
    /// always.
    func testDownloadProgressRedrawsInWholePercentStepsAtMostFourTimesASecond() {
        let s = ModelDownloadManager.shouldPublish
        XCTAssertTrue(s(nil, 0.0001, 0), "the first value always goes out")
        XCTAssertFalse(s((0.10, 10), 0.105, 11), "half a percent is not a redraw")
        XCTAssertFalse(s((0.10, 10), 0.13, 10.1), "three percent in 0.1 s waits")
        XCTAssertTrue(s((0.10, 10), 0.11, 10.3))
        XCTAssertTrue(s((0.999, 10), 1.0, 10.01), "the end always goes out")

        // A fast link: 3.1 GB at 60 MB/s in 64 KB callbacks for one second.
        var last: (Double, TimeInterval)? = nil
        var redraws = 0
        let total = 3_100_000_000.0, chunk = 65_536.0, perSecond = 60_000_000.0
        var written = 0.0
        while written < perSecond {
            written += chunk
            let now = written / perSecond
            if s(last, written / total, now) { last = (written / total, now); redraws += 1 }
        }
        XCTAssertLessThanOrEqual(redraws, 5, "\(redraws) redraws in one second")
    }

    /// Parakeet TDT 1.1B: the bundled loader rejects 42 encoder layers, so the
    /// catalogue must not offer it.
    func testTheCatalogueDoesNotOfferModelsTheEngineCannotLoad() {
        for lang in [nil, VoiceLang.english, .universal] {
            let ids = Set(VoiceCatalog.filtered(task: .stt, lang: lang).map(\.id))
            XCTAssertTrue(ids.isDisjoint(with: VoiceCatalog.unloadable), "offered for \(String(describing: lang))")
        }
        XCTAssertTrue(VoiceCatalog.all.contains { VoiceCatalog.unloadable.contains($0.id) },
                      "a copy already downloaded must still be found (to be deleted)")
    }
}
