import ScionicMerkleTree
import XCTest

final class SyncBetweenTwoStoresExample: XCTestCase {
    // Anything that answers requests is a peer: here, a store in the same
    // program.
    func testSyncBetweenTwoStores() throws {
        var printed: [String] = []
        func print(_ items: Any...) {
            printed.append(items.map { "\($0)" }.joined(separator: " "))
        }

        // A publisher builds a tree. Here it is built from bytes in memory.
        let publisher = MemoryStore()
        let builder = Builder(store: publisher, chunking: .fastCDCv1)
        let readme = try builder.file(bytes: Array("# My model\n".utf8))
        let weights = try builder.file(bytes: [UInt8](repeating: 7, count: 3 << 20))
        let top = try builder.folder([
            Entry(name: "README.md", target: readme),
            Entry(name: "weights.bin", target: weights),
        ])
        let root = try builder.finish(top: top)

        // A responder answers requests from the publisher's store.
        let peer = Responder(publisher)

        // Read a part of the tree and keep nothing: find one file by its name,
        // then take 16 bytes from the middle of it. Only the chunk that holds
        // those bytes is sent, and it is verified against the root.
        let remote = try Remote(peer: peer, root: root)
        if let entry = try remote.lookup("weights.bin") {
            let middle = MemorySink()
            try remote.read(entry.target, offset: 1 << 20, length: 16, to: middle)
            print(middle.bytes)
        }

        // Or fetch the whole tree into another store. Each part is verified
        // before it is kept, and what the store already holds is skipped.
        let mirror = MemoryStore()
        let summary = try fetch(mirror, root, from: peer)
        print(summary.files, "files")

        XCTAssertEqual(printed, ["[7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]", "2 files"])
    }
}
