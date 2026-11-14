// A tree whose bytes were harmed where they are kept: the harm is found and
// named, it can be removed and fetched again, and nothing that a peer sends can
// make a store give up what is sound.

import XCTest
@testable import ScionicMerkleTree

final class DamageTests: XCTestCase {
    func testADamagedChunkIsNamedAndTheStoreIsLeftAsItIs() throws {
        let (_, store, root) = try sampleTree("damage-named")
        let model = try targetAt(store, root, "weights/model.bin")
        let chunk = try fileOf(store, model).items[3]
        let rot = corpusBytes("rot", Int(chunk.length))
        try swapIn(store, .chunk, chunk.hash, rot)
        for workers in [0, 1, 4] {
            let error = assertFails(try verify(store, root, options: VerifyOptions(workers: workers)), "corrupt", "\(workers) workers")
            if case let .corrupt(what, hash)? = error {
                XCTAssertEqual(what, "a stored chunk")
                XCTAssertEqual(hash, chunk.hash)
            }
        }
        // Checking changes nothing unless it is told to.
        XCTAssertEqual(try store.get(.chunk, chunk.hash), rot)
    }

    func testDamageIsRemovedWhenAskedAndAFetchMakesTheTreeWhole() throws {
        let (_, source, root) = try sampleTree("damage-mended")
        let dest = MemoryStore()
        try fetch(dest, root, from: TestPeer(source))
        _ = try verify(dest, root)
        let model = try targetAt(dest, root, "weights/model.bin")
        let weights = try targetAt(dest, root, "weights")
        let list = try fileOf(dest, model)

        // Two chunks: one harmed at its own length, one at another length.
        let (same, other) = (list.items[1], list.items[4])
        try swapIn(dest, .chunk, same.hash, corpusBytes("rot-1", Int(same.length)))
        try swapIn(dest, .chunk, other.hash, corpusBytes("rot-2", 7))
        let error = assertFails(try verify(dest, root, options: VerifyOptions(discardDamaged: true)), "missing")
        if case let .missing(what, _)? = error {
            XCTAssertEqual(what, "the chunk")
        }
        XCTAssertFalse(try dest.has(.chunk, same.hash))
        XCTAssertFalse(try dest.has(.chunk, other.hash))
        try fetch(dest, root, from: TestPeer(source))
        _ = try verify(dest, root)

        // A list and the record: checking names them, and a fetch replaces them
        // without being told to, because it cannot go on with them.
        let cases: [(Stored, Hash, [UInt8], String)] = [
            (.folderList, weights.hash, [UInt8](repeating: 9, count: 50), "a stored folder's list"),
            (.fileList, model.hash, [UInt8](repeating: 7, count: 72), "a stored file's list"),
            (.record, root.hash, [UInt8](repeating: 0x20, count: 80), "a stored record"),
        ]
        for (kind, hash, harmed, what) in cases {
            try swapIn(dest, kind, hash, harmed)
            if case let .corrupt(named, damaged)? = assertFails(try verify(dest, root), "corrupt", what) {
                XCTAssertEqual(named, what)
                XCTAssertEqual(damaged, hash)
            }
            try fetch(dest, root, from: TestPeer(source))
            _ = try verify(dest, root)
        }
    }

    func testAListThatLiesAboutAChunkCannotCostAStoreTheChunk() throws {
        // A sound chunk of 16 bytes, and a file's list that gives it 15.
        let whole = corpusBytes("sound", 16)
        let item = try ChunkRef.of(whole)
        let lying = try FileList(items: [ChunkRef(hash: item.hash, length: 15)])
        let totals = Totals(chunks: 1, chunkBytes: 15, listBytes: 36)
        let record = try Record(top: lying.target, totals: totals, chunking: smallChunks())
        let root = Root.of(record: record.encode())
        let forger = MemoryStore()
        try forger.put(.record, root.hash, record.encode())
        try forger.put(.fileList, lying.hash, lying.encode())

        // A holder of the chunk is sent the tree. The tree is refused, and the
        // chunk stays: bytes that hash to what they are kept under are sound,
        // whatever a list says of them.
        let holder = MemoryStore()
        try holder.put(.chunk, item.hash, whole)
        assertFails(try fetch(holder, root, from: TestPeer(forger)), "sizeMismatch")
        XCTAssertEqual(try holder.get(.chunk, item.hash), whole)
        // The same when the list is in the store already.
        try forger.put(.chunk, item.hash, whole)
        assertFails(try Intake(store: forger, root: root), "sizeMismatch")
        assertFails(try verify(forger, root, options: VerifyOptions(discardDamaged: true)), "sizeMismatch")
        XCTAssertTrue(try forger.has(.chunk, item.hash))
    }
}
