import Foundation
@testable import roundtrip
import ScionicMerkleTree
import XCTest

final class RoundtripTests: XCTestCase {
    // The example is run, so that it cannot fall behind the library: a folder
    // goes its whole way round through the store on disk, and comes back as
    // the same tree.
    func testAFolderGoesItsWholeWayRound() throws {
        let temp = try TempDir("roundtrip")
        let folder = temp.join("my-model")
        let files: [String: [UInt8]] = [
            "config.json": Array("{\"layers\": 12}\n".utf8),
            "weights/model.bin": [UInt8](repeating: 7, count: 3 << 20),
            "weights/again.bin": [UInt8](repeating: 7, count: 3 << 20),
            "notes/empty.txt": [],
            "notes/deep/more.md": Array("# Notes\n".utf8),
        ]
        for (name, content) in files {
            try writeFile(folder + "/" + name, content)
        }
        let work = temp.join("work")
        var out = ""
        let root = try roundtrip(folder, work, to: &out)
        for want in [
            "root         \(root)",
            // The two files of 3 MiB are one file, kept once.
            "the tree     6291479 bytes; kept once: 3 chunks of 3145751 bytes",
            "4 different files in 4 different folders",
            "4096 bytes at a time, from 64 places in a file of 3145728 bytes",
            "the copy has the same root",
        ] {
            XCTAssertTrue(out.contains(want), "the example did not print \(want):\n\(out)")
        }
        // What was written out is what was built from, byte for byte.
        for (name, content) in files {
            XCTAssertEqual(try fileBytes(work + "/written/" + name), content, "\(name) did not come back as it was")
        }
        // A second run needs a folder of its own.
        XCTAssertThrowsError(try roundtrip(folder, work, to: &out), "a work folder that is there already was used again")
    }

    func testTheStoreOnDiskKeepsAndGivesBack() throws {
        let temp = try TempDir("folder-store")
        let store = FolderStore(temp.path)
        let content = Array("a chunk".utf8)
        let hash = Hash.of(content)
        XCTAssertNil(try store.get(.chunk, hash))
        XCTAssertNil(try store.size(.chunk, hash))
        // Kept twice, it is kept once.
        for _ in 0..<2 {
            try store.put(.chunk, hash, content)
        }
        XCTAssertEqual(try store.get(.chunk, hash), content)
        XCTAssertEqual(try store.size(.chunk, hash), 7)
        XCTAssertTrue(try store.has(.chunk, hash))
        // A thing is kept by its kind: the same hash as another kind is not it.
        XCTAssertNil(try store.get(.fileList, hash))
        // Removed twice, it is gone, and that is no error.
        for _ in 0..<2 {
            try store.remove(.chunk, hash)
        }
        XCTAssertNil(try store.get(.chunk, hash))
        XCTAssertFalse(try store.has(.chunk, hash))
    }
}
