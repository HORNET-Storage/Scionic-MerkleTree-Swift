// Whatever is held open on disk is let go of, however the work ends: after an
// error, and after a store that falls over. And a writer that fails is told as
// it failed.

import Foundation
import XCTest
@testable import ScionicMerkleTree

final class LetGoTests: XCTestCase {
    func testAStoreThatFallsOverDoesNotLeaveWhatWasWrittenHeld() throws {
        let (temp, store, root) = try sampleTree("letgo-written")
        let falling = FallingOnGet(store)
        let dest = temp.join("written")
        // The store falls over when the first chunk is read, which is when the
        // first file is open and being written into its new folder.
        assertFell(endsWithin("writing a tree out") { try writeToDisk(falling, root, to: dest) }, "writing a tree out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest), "the store fell over before anything was written")
        XCTAssertNoThrow(try movable(dest), "what was written is still held after the store fell over")
        try FileManager.default.removeItem(atPath: dest)

        // The same for a tree that is one file.
        let file = try targetAt(store, root, "weights/model.bin")
        let alone = try Builder(store: store, chunking: smallChunks()).finish(top: file)
        let destFile = temp.join("written.bin")
        assertFell(endsWithin("writing a file out") { try writeToDisk(falling, alone, to: destFile) }, "writing a file out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile))
        XCTAssertNoThrow(try FileManager.default.removeItem(atPath: destFile), "the file that was being written is still open")
    }

    func testAWriterThatFailsIsToldAsItFailed() throws {
        let (_, store, root) = try sampleTree("letgo-writer")
        let model = try targetAt(store, root, "weights/model.bin")
        func toldAsBroken(_ error: ScionicError?, _ what: String, operation: String? = nil) {
            guard case let .stream(told, failure)? = error else {
                return XCTFail("\(what): \(String(describing: error))")
            }
            XCTAssertTrue(failure is BrokenSink.Broken, "\(what): \(failure)")
            if let operation {
                XCTAssertEqual(told, operation, what)
            }
        }
        for left in [0, 1, 16, 17, 999] {
            let error = assertFails(try readFile(store, model, to: BrokenSink(left: left)), "stream")
            toldAsBroken(error, "after \(left) bytes", operation: "write a file's bytes")
        }
        XCTAssertNoThrow(try readFile(store, model, to: BrokenSink(left: 1_000)))
        // The same for one who reads from a peer and keeps nothing.
        let remote = try Remote(peer: TestPeer(store), root: root)
        toldAsBroken(assertFails(try remote.read(model, offset: 0, length: 1_000, to: BrokenSink(left: 500)), "stream"), "from a peer")
        // And a bundle that cannot be written.
        toldAsBroken(assertFails(try exportBundle(store, root, to: BrokenSink(left: 100)), "stream"), "a bundle")
    }
}
