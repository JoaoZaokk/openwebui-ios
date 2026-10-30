import XCTest
import UIKit
@testable import OpenWebUI

/// Report from 1.10 (zh_CN): the chat background could not be set to a
/// picture. A photo picked in Settings is kept, shrunk, beside the app's data.
final class ChatWallpaperTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString)")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func photo(_ w: CGFloat, _ h: CGFloat) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func testAPickedPhotoIsKeptShrunkAndCanBeRemoved() throws {
        let store = ChatWallpaper(directory: dir)
        XCTAssertNil(store.image())
        try store.save(photo(4032, 3024))
        let kept = try XCTUnwrap(store.image())
        XCTAssertLessThanOrEqual(max(kept.size.width, kept.size.height), ChatWallpaper.maxDimension)
        store.remove()
        XCTAssertNil(store.image())
    }

    func testSomethingThatIsNotAPictureIsRefused() {
        let store = ChatWallpaper(directory: dir)
        XCTAssertThrowsError(try store.save(Data("not a picture".utf8)))
        XCTAssertNil(store.image())
    }
}
