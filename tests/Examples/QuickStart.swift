import ScionicMerkleTree
import XCTest

final class QuickStartExample: XCTestCase {
    // A folder becomes a Scionic Merkle Tree, the tree is verified, one file is
    // read out of it, and the tree is written back to disk.
    func testQuickStart() throws {
        var printed: [String] = []
        func print(_ items: Any...) {
            printed.append(items.map { "\($0)" }.joined(separator: " "))
        }
        // The example works in a folder of its own, which holds a small model.
        let undo = try workIn([
            "models/my-model/config.json": Array("{\"layers\": 12}\n".utf8),
            "models/my-model/weights/model.bin": [UInt8](repeating: 7, count: 3 << 20),
        ])
        defer { undo() }

        // A store keeps chunks and lists by their hashes. This one is in memory.
        let store = MemoryStore()

        // Build a tree from a folder. The root depends on the folder's contents
        // alone: not on where the folder is, what it is called, or how many
        // threads built it.
        let root = try build(store, path: "models/my-model")
        print(root) // bafkrei...

        // Verify everything the store holds for that root: every list, every chunk.
        let summary = try verify(store, root)
        print("\(summary.files) files, \(summary.record.top.size) bytes")

        // Read one file by its path in the tree.
        if let entry = try lookup(store, root, path: "config.json") {
            let content = try readFile(store, entry.target)
            print("config.json holds \(content.count) bytes")
        }

        // Write the whole tree back out, to a path that does not exist yet.
        try writeToDisk(store, root, to: "restored")

        // The root is the one that the Go and Rust libraries give the same folder.
        XCTAssertEqual(printed, [
            "bafkreifxao4std4w2b2cmzl6boesplar2mlntpqdwx43ujnvijef7hbbsy",
            "2 files, 3145743 bytes",
            "config.json holds 15 bytes",
        ])
        XCTAssertEqual(try build(MemoryStore(), path: "restored"), root)
    }
}
