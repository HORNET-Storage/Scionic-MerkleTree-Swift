// Checking a whole tree that a store holds.

import XCTest
@testable import ScionicMerkleTree

/// Puts other bytes under a hash that the store holds already.
func swapIn(_ store: MemoryStore, _ kind: Stored, _ hash: Hash, _ bytes: [UInt8]) throws {
    try store.remove(kind, hash)
    try store.put(kind, hash, bytes)
}

func kept(_ store: MemoryStore, _ kind: Stored, _ hash: Hash) throws -> [UInt8] {
    guard let bytes = try store.get(kind, hash) else {
        throw TestFailure("nothing is kept under \(hash)")
    }
    return bytes
}

/// Puts a file into a store by hand, with whatever chunks it is given.
func fileByHand(_ store: MemoryStore, _ chunks: [[UInt8]]) throws -> Target {
    var items: [ChunkRef] = []
    for chunk in chunks {
        let item = try ChunkRef.of(chunk)
        try store.put(.chunk, item.hash, chunk)
        items.append(item)
    }
    let list = try FileList(items: items)
    try store.put(.fileList, list.hash, list.encode())
    return list.target
}

final class VerifyTests: XCTestCase {
    func testAWholeTreeChecksAndAMissingPartIsNamed() throws {
        let (_, store, root) = try sampleTree("verify-missing")
        _ = try verify(store, root)
        _ = try verify(store, root, options: VerifyOptions(rechunk: true))

        let model = try targetAt(store, root, "weights/model.bin")
        let weights = try targetAt(store, root, "weights")
        let chunk = try fileOf(store, model).items[5]
        let cases: [(Stored, Hash, String)] = [
            (.chunk, chunk.hash, "the chunk"),
            (.fileList, model.hash, "the list of the file"),
            (.folderList, weights.hash, "the list of the folder"),
            (.record, root.hash, "the record of"),
        ]
        for (kind, hash, what) in cases {
            let bytes = try kept(store, kind, hash)
            try store.remove(kind, hash)
            if case let .missing(named, missing)? = assertFails(try verify(store, root), "missing", what) {
                XCTAssertEqual(named, what)
                XCTAssertEqual(missing, hash)
            }
            try store.put(kind, hash, bytes)
            _ = try verify(store, root)
        }
    }

    func testBytesThatChangedInTheStoreAreFound() throws {
        let (_, store, root) = try sampleTree("verify-changed")
        let model = try targetAt(store, root, "weights/model.bin")
        let shard = try targetAt(store, root, "weights/shards/a.bin")
        let weights = try targetAt(store, root, "weights")
        let data = try targetAt(store, root, "data")
        let chunk = try fileOf(store, model).items[5]

        let cases: [(Stored, Hash, [UInt8], String)] = [
            (.chunk, chunk.hash, corpusBytes("other", 16), "a chunk's bytes"),
            (.chunk, chunk.hash, corpusBytes("other", 15), "a chunk cut short"),
            (.chunk, chunk.hash, corpusBytes("other", 17), "a chunk made longer"),
            (.fileList, model.hash, try kept(store, .fileList, shard.hash), "another file's list"),
            (.fileList, model.hash, [UInt8](repeating: 7, count: 35), "no list at all"),
            (.folderList, weights.hash, try kept(store, .folderList, data.hash), "another folder's list"),
            (.folderList, weights.hash, [UInt8](repeating: 9, count: 50), "no list at all"),
            (.record, root.hash, [UInt8](repeating: 0x20, count: 80), "another record"),
        ]
        for (kind, hash, forged, what) in cases {
            let honest = try kept(store, kind, hash)
            try swapIn(store, kind, hash, forged)
            if let error = assertFails(try verify(store, root), nil, what) {
                XCTAssertTrue(["corrupt", "sizeMismatch", "invalidData"].contains(error.caseName), "\(what): \(error)")
            }
            try swapIn(store, kind, hash, honest)
            _ = try verify(store, root)
        }
    }

    func testARecordWithWrongTotalsIsRefused() throws {
        let (_, store, root) = try sampleTree("verify-totals")
        let record = try recordOf(store, root)
        let right = record.totals
        func with(_ change: (inout Totals) -> Void) -> Totals {
            var totals = right
            change(&totals)
            return totals
        }
        let wrong: [(String, Totals)] = [
            ("chunks", with { $0.chunks -= 1 }),
            ("chunks", with { $0.chunks += 1 }),
            ("chunk bytes", with { $0.chunkBytes -= 1 }),
            ("chunk bytes", with { $0.chunkBytes += 1 }),
            ("list bytes", with { $0.listBytes -= 1 }),
            ("list bytes", with { $0.listBytes += 1 }),
        ]
        for (field, totals) in wrong {
            let forged = try Record(top: record.top, totals: totals, chunking: record.chunking)
            let forgedRoot = forged.root
            XCTAssertNotEqual(forgedRoot, root)
            try store.put(.record, forgedRoot.hash, forged.encode())
            if case let .totalsMismatch(named, _, _)? = assertFails(try verify(store, forgedRoot), "totalsMismatch", "\(totals)") {
                XCTAssertEqual(named, field)
            }
        }
    }

    func testAnEntryCannotGiveWhatIsUnderItAnotherSize() throws {
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let file = try builder.file(bytes: corpusBytes("sized", 70))
        let folder = try builder.folder([Entry(name: "f", target: file)])
        func grown(_ target: Target) -> Target {
            var grown = target
            grown.size += 1
            return grown
        }

        let cases: [[Entry]] = [
            [try Entry(name: "f", target: grown(file))],
            [try Entry(name: "d", target: grown(folder))],
            // The same file under two names, once with its size and once not.
            [try Entry(name: "a", target: file), try Entry(name: "b", target: grown(file))],
            [try Entry(name: "a", target: grown(file)), try Entry(name: "b", target: file)],
        ]
        for entries in cases {
            let builder = Builder(store: store, chunking: smallChunks())
            let top = try builder.folder(entries)
            assertFails(try builder.finish(top: top), "sizeMismatch", "\(entries.map(\.name))")
        }
        let top = try builder.folder([Entry(name: "d", target: folder), Entry(name: "f", target: file)])
        let root = try builder.finish(top: top)
        XCTAssertEqual(try verify(store, root).record.top.size, 140)
    }

    func testEveryFileIsHeldToTheWayItsTreeWasChunked() throws {
        let store = MemoryStore()
        let (first, short, last) = (corpusBytes("p0", 16), corpusBytes("p1", 9), corpusBytes("p2", 16))
        // A chunk in the middle that is shorter than the tree's chunks.
        let uneven = try fileByHand(store, [first, short, last])
        // A last chunk that is longer than the tree's chunks.
        let longTail = try fileByHand(store, [first, corpusBytes("tail", 17)])
        for file in [uneven, longTail] {
            let builder = Builder(store: store, chunking: smallChunks())
            let top = try builder.folder([Entry(name: "f", target: file)])
            assertFails(try builder.finish(top: top), "invalidData")
            // A tree of the file alone is refused as well.
            assertFails(try Builder(store: store, chunking: smallChunks()).finish(top: file))
        }

        // Small chunks are no chunks of a tree that is chunked by content.
        let even = try fileByHand(store, [first, last, short])
        _ = try Builder(store: store, chunking: smallChunks()).finish(top: even)
        assertFails(try Builder(store: store, chunking: .fastCDCv1).finish(top: even))
        // A file of one small chunk fits either way.
        let single = try fileByHand(store, [short])
        for chunking in [smallChunks(), Chunking.fastCDCv1] {
            let root = try Builder(store: store, chunking: chunking).finish(top: single)
            _ = try verify(store, root)
        }
    }

    func testChunkingAgainFindsAFileThatWasChunkedAnotherWay() throws {
        let data = corpusBytes("scionic-fastcdc-v1:corpus:random_3mib", 3 << 20)
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: .fastCDCv1)
        let honest = try builder.file(bytes: data)
        let root = try builder.finish(top: honest)
        let rechunk = VerifyOptions(rechunk: true)
        _ = try verify(store, root, options: rechunk)

        // The same bytes, cut in the middle. Each half is long enough to pass for
        // a chunk that the chunker made, so its lengths alone give nothing away.
        // It is another file: the same bytes under another hash.
        let forged = try fileByHand(store, [Array(data[..<(3 << 19)]), Array(data[(3 << 19)...])])
        XCTAssertEqual(forged.size, honest.size)
        XCTAssertNotEqual(forged.hash, honest.hash)
        let forgedRoot = try Builder(store: store, chunking: .fastCDCv1).finish(top: forged)
        _ = try verify(store, forgedRoot)
        assertFails(try verify(store, forgedRoot, options: rechunk), "invalidData")
    }

    func testAChunkCannotBeListedWithTwoLengths() throws {
        let store = MemoryStore()
        let whole = corpusBytes("whole", 16)
        let right = try fileByHand(store, [whole])
        let item = try ChunkRef.of(whole)
        let shorter = try FileList(items: [ChunkRef(hash: item.hash, length: 15)])
        try store.put(.fileList, shorter.hash, shorter.encode())

        // The chunk is held with 16 bytes, so a list that gives it 15 is wrong on
        // its own, and wrong beside a list that gives it 16.
        let cases: [[Entry]] = [
            [try Entry(name: "wrong", target: shorter.target)],
            [try Entry(name: "a-right", target: right), try Entry(name: "b-wrong", target: shorter.target)],
            [try Entry(name: "a-wrong", target: shorter.target), try Entry(name: "b-right", target: right)],
        ]
        for entries in cases {
            let builder = Builder(store: store, chunking: smallChunks())
            let top = try builder.folder(entries)
            assertFails(try builder.finish(top: top), "sizeMismatch")
        }

        // Without the chunk's bytes, two lists that disagree are still refused.
        let bare = MemoryStore()
        for list in [shorter, try FileList(items: [item])] {
            try bare.put(.fileList, list.hash, list.encode())
        }
        let builder = Builder(store: bare, chunking: smallChunks())
        let top = try builder.folder([Entry(name: "a", target: right), Entry(name: "b", target: shorter.target)])
        assertFails(try builder.finish(top: top), "sizeMismatch")
    }

    func testATreeIsCheckedByItsRootAndByNothingElse() throws {
        let (_, store, root) = try sampleTree("verify-root")
        // A root that the store has no record for.
        let unknown = Root.of(record: bytes("nothing is kept under this"))
        if case let .missing(what, _)? = assertFails(try verify(store, unknown), "missing") {
            XCTAssertEqual(what, "the record of")
        }
        // The record of one tree, kept under the root of another.
        try store.put(.record, unknown.hash, kept(store, .record, root.hash))
        assertFails(try verify(store, unknown), "corrupt")
        // A folder is checked once, however many names it has.
        let weights = try targetAt(store, root, "weights")
        let builder = Builder(store: store, chunking: smallChunks())
        let top = try builder.folder([Entry(name: "one", target: weights), Entry(name: "two", target: weights)])
        let twice = try builder.finish(top: top)
        let summary = try verify(store, twice)
        XCTAssertEqual(summary.folders, 3, "the top, `weights` and `shards`")
        XCTAssertEqual(summary.record.top.size, 2 * weights.size)
        XCTAssertEqual(try folderOf(store, top).count, 2)
    }
}
