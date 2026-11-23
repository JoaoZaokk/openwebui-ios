import XCTest
import AVFoundation
@testable import OpenWebUI

/// The pure parts of the answers to the report on build 27: which microphone a
/// call records from, and what an interrupted download leaves behind.
final class Build28ReportTests: XCTestCase {

    // MARK: - Microphone

    /// "The audio output routes over Bluetooth, but the microphone itself is the
    /// phone's" — a worn microphone wins over the built-in one.
    func testAWornMicrophoneIsPreferredOverThePhone() {
        typealias P = AVAudioSession.Port
        XCTAssertEqual(VoiceInputManager.preferredInput(among: [P.builtInMic, P.bluetoothHFP]), 1)
        XCTAssertEqual(VoiceInputManager.preferredInput(among: [P.headsetMic, P.builtInMic, P.bluetoothHFP]), 2,
                       "the Bluetooth headset is the one being worn when both are there")
        XCTAssertEqual(VoiceInputManager.preferredInput(among: [P.builtInMic, P.carAudio]), 1)
        XCTAssertEqual(VoiceInputManager.preferredInput(among: [P.builtInMic, P.headsetMic]), 1)
        XCTAssertNil(VoiceInputManager.preferredInput(among: [P.builtInMic]), "nothing worn: leave the system default")
        XCTAssertNil(VoiceInputManager.preferredInput(among: []))
    }

    // MARK: - Interrupted downloads

    /// The sweep takes URLSession's partial files and a half-unpacked Core ML
    /// folder, and nothing else that lives in tmp.
    func testTheSweepTakesPartialDownloadsAndLeavesTheRest() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let partial = tmp.appendingPathComponent("CFNetworkDownload_AbC123.tmp")
        try Data(count: 300_000).write(to: partial)
        let unpack = tmp.appendingPathComponent("ml-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: unpack.appendingPathComponent("weights.bin"))
        let keep = tmp.appendingPathComponent("photo.jpg")
        try Data(count: 10).write(to: keep)
        let keepDir = tmp.appendingPathComponent("ml-notes.txt")   // a file, not an unpack folder
        try Data(count: 10).write(to: keepDir)

        let freed = ModelDownloadManager.sweepPartialDownloads(in: tmp)

        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertFalse(fm.fileExists(atPath: unpack.path))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertTrue(fm.fileExists(atPath: keepDir.path))
        XCTAssertGreaterThanOrEqual(freed, 350_000)
    }

    /// Where the half file really is: a download cut off mid-way leaves a
    /// `CFNetworkDownload_*.tmp` in the app's tmp folder, which the sweep then
    /// removes. Against the network (a model file on Hugging Face).
    func testACutOffDownloadLeavesAPartialThatTheSweepRemoves() throws {
        let tmp = FileManager.default.temporaryDirectory
        ModelDownloadManager.sweepPartialDownloads(in: tmp)
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
        let got = expectation(description: "bytes arrived")
        final class Watch: NSObject, URLSessionDownloadDelegate {
            let got: XCTestExpectation; var fired = false
            init(_ e: XCTestExpectation) { got = e }
            func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
                if totalBytesWritten > 2_000_000, !fired { fired = true; got.fulfill() }
            }
            func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        }
        let watch = Watch(got)
        let session = URLSession(configuration: .default, delegate: watch, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
        wait(for: [got], timeout: 60)
        // What an interrupted download keeps: cancel with resume data, as the
        // system does when it cuts a task off.
        let cut = expectation(description: "cut")
        var resume: Data?
        task.cancel { resume = $0; cut.fulfill() }
        wait(for: [cut], timeout: 20)
        session.finishTasksAndInvalidate()
        XCTAssertNotNil(resume, "a cut-off download should be resumable")

        let partials = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix("CFNetworkDownload_") }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertFalse(partials.isEmpty, "no partial in \(tmp.path): \(listing)")

        let freed = ModelDownloadManager.sweepPartialDownloads(in: tmp)
        XCTAssertGreaterThan(freed, 2_000_000)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix("CFNetworkDownload_") }.isEmpty)
    }
}
