// Syncing by file hash and chunk number: a whole tree into a store, parts of a
// tree straight from a peer, and a tree as one stream.

import Foundation
import XCTest
@testable import ScionicMerkleTree

func targetAt(_ store: MemoryStore, _ root: Root, _ path: String) throws -> Target {
    guard let entry = try lookup(store, root, path: path) else {
        throw TestFailure("\(path) is not in the tree")
    }
    return entry.target
}

final class SyncTests: XCTestCase {
    func testATreeIsFetchedWholeIntoAnEmptyStore() throws {
        let (_, source, root) = try sampleTree("sync-whole")
        let dest = MemoryStore()
        let peer = TestPeer(source)
        let summary = try fetch(dest, root, from: peer)
        XCTAssertEqual(summary, try verify(dest, root))
        XCTAssertEqual(try contents(dest), try contents(source))

        // Each thing came once: the record, 5 folders, 6 files, 76 chunks.
        XCTAssertEqual(peer.wire.framesOf(FrameTag.record), 1)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.folderList), 5)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.fileList), 6)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.chunk), 76)
        XCTAssertEqual(peer.wire.frames.count, 88)

        // From the top down. The record is asked for first, a list only once the
        // list that names it is in, and chunks only by their file's hash and
        // their numbers in it.
        var known = [root.hash]
        var askedChunks: UInt64 = 0
        for request in peer.wire.requests {
            switch try Request(decoding: request) {
            case let .record(asked):
                XCTAssertEqual(asked, root)
            case let .folder(folder):
                XCTAssertTrue(known.contains(folder))
                let list = try FolderList(decoding: XCTUnwrap(dest.get(.folderList, folder)))
                known.append(contentsOf: list.entries.map(\.hash))
            case let .file(file):
                XCTAssertTrue(known.contains(file))
            case let .chunks(file, _, count):
                XCTAssertTrue(known.contains(file))
                askedChunks += UInt64(count)
            case let other:
                XCTFail("a whole tree is not fetched by \(other)")
            }
            if known.count == 1 {
                known.append(try recordOf(dest, root).top.hash)
            }
        }
        XCTAssertEqual(askedChunks, 76)
    }

    func testChunksAreAskedForByTheirFileAndTheirNumbers() throws {
        let (_, source, root) = try sampleTree("sync-numbers")
        let peer = TestPeer(source)
        try fetch(MemoryStore(), root, from: peer)
        let model = try targetAt(source, root, "weights/model.bin")
        // The file has 63 chunks, and two names. All of its chunks are asked for
        // once, in one request of 45 bytes.
        let forModel = try peer.wire.requests.filter { request in
            if case let .chunks(file, _, _) = try Request(decoding: request) {
                return file == model.hash
            }
            return false
        }
        XCTAssertEqual(forModel.count, 1)
        XCTAssertEqual(forModel.first?.count, 45)
        XCTAssertEqual(try Request(decoding: forModel[0]), .chunks(file: model.hash, start: 0, count: 63))
    }

    func testWhatAReceiverHoldsIsNotAskedForAgain() throws {
        let temp = try TempDir("sync-held")
        let folder = try sampleFolder(temp.path, "sample")
        let source = MemoryStore()
        let first = try build(source, path: folder, options: smallOptions())
        let dest = MemoryStore()
        try fetch(dest, first, from: TestPeer(source))

        // A second tree: one chunk of one file changed, a file that is there
        // already under another name, and one new file of two chunks.
        var model = corpusBytes("model", 1_000)
        model.replaceSubrange(320..<336, with: corpusBytes("changed", 16))
        try writeFile(folder + "/weights/model.bin", model)
        try writeFile(folder + "/weights/a-again.bin", corpusBytes("shard-a", 100))
        try writeFile(folder + "/new.txt", corpusBytes("new", 20))
        let second = try build(source, path: folder, options: smallOptions())

        let peer = TestPeer(source)
        try fetch(dest, second, from: peer)
        // The record, the two folders on the way to the changes, the lists of the
        // changed file and the new one, and three chunks.
        XCTAssertEqual(peer.wire.framesOf(FrameTag.record), 1)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.folderList), 2)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.fileList), 2)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.chunk), 3)
        // The one changed chunk of the file was asked for by its number.
        let changed = try targetAt(source, second, "weights/model.bin")
        XCTAssertTrue(peer.wire.requests.contains(Request.chunks(file: changed.hash, start: 20, count: 1).encode()))
        _ = try verify(dest, first)
        _ = try verify(dest, second)

        // A tree that is held whole is not asked about at all.
        let idle = TestPeer(source)
        try fetch(dest, second, from: idle)
        XCTAssertTrue(idle.wire.requests.isEmpty)
    }

    func testChunksHeldFromAnywhereElseAreSkippedByTheirHash() throws {
        let (_, source, root) = try sampleTree("sync-elsewhere")
        let model = try targetAt(source, root, "weights/model.bin")
        let dest = MemoryStore()
        // The receiver has the file's bytes from somewhere else, as bare chunks.
        for item in try fileOf(source, model).items {
            try dest.put(.chunk, item.hash, XCTUnwrap(source.get(.chunk, item.hash)))
        }
        let peer = TestPeer(source)
        try fetch(dest, root, from: peer)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.chunk), 76 - 63)
        _ = try verify(dest, root)
    }

    func testAFetchThatStopsGoesOnFromWhatIsHeld() throws {
        let (_, source, root) = try sampleTree("sync-resume")
        let dest = MemoryStore()
        // A peer that goes silent after 30 frames.
        var left = 30
        let flaky = TestPeer(source) { _, frames in
            let keep = min(frames.count, left)
            left -= keep
            return Array(frames.prefix(keep))
        }
        assertFails(try fetch(dest, root, from: flaky), "peer")
        XCTAssertEqual(flaky.wire.frames.count, 30)
        assertFails(try verify(dest, root), "missing")

        let peer = TestPeer(source)
        try fetch(dest, root, from: peer)
        XCTAssertEqual(peer.wire.frames.count, 88 - 30, "nothing came twice")
        XCTAssertEqual(peer.wire.framesOf(FrameTag.record), 0)
        _ = try verify(dest, root)
    }

    func testOneNameIsLookedUpWithoutTheFolder() throws {
        let (_, source, root) = try sampleTree("sync-name")
        let peer = TestPeer(source)
        let remote = try Remote(peer: peer, root: root)
        XCTAssertEqual(remote.record, try recordOf(source, root))
        for path in ["readme.txt", "weights", "weights/model.bin", "weights/shards/a.bin", "nothing-here"] {
            XCTAssertEqual(try remote.lookup(path), try lookup(source, root, path: path), path)
            XCTAssertNotNil(try remote.lookup(path), path)
        }
        for path in ["a", "zzz", "readme.txs", "weights/shards/aa.bin", "weights/model.bin/x", "nothing-here/x", "Weights"] {
            XCTAssertNil(try remote.lookup(path), path)
        }
        assertFails(try remote.lookup("weights/../readme.txt"))
        // The record, and one small frame for each name on the way: no folder's
        // whole list, no file's list, and no chunk.
        XCTAssertEqual(peer.wire.framesOf(FrameTag.record), 1)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.folderBranch), peer.wire.frames.count - 1)
        XCTAssertTrue(peer.wire.frames.allSatisfy { $0.count < 600 })
    }

    func testAStretchOfAFileIsReadWithoutTheRest() throws {
        let (_, source, root) = try sampleTree("sync-stretch")
        let model = try targetAt(source, root, "weights/model.bin")
        let content = corpusBytes("model", 1_000)
        var peer = TestPeer(source)
        var remote = try Remote(peer: peer, root: root)
        var out = BytesSink()
        try remote.read(model, offset: 100, length: 333, to: out)
        XCTAssertEqual(out.bytes, Array(content[100..<433]))
        // Bytes 100 to 432 lie in chunks 6 to 27. The record, one branch of the
        // file's list, and those 22 chunks came, and nothing else.
        XCTAssertEqual(peer.wire.framesOf(FrameTag.fileBranch), 1)
        XCTAssertEqual(peer.wire.framesOf(FrameTag.chunk), 22)
        XCTAssertEqual(peer.wire.frames.count, 24)
        XCTAssertTrue(peer.wire.requests.contains(Request.chunks(file: model.hash, start: 6, count: 22).encode()))

        peer = TestPeer(source)
        remote = try Remote(peer: peer, root: root)
        for (offset, length): (UInt64, UInt64) in [(0, 1), (0, 16), (15, 2), (16, 16), (999, 1), (992, 8), (0, 1_000), (500, 0), (1_000, 0)] {
            out = BytesSink()
            try remote.read(model, offset: offset, length: length, to: out)
            XCTAssertEqual(out.bytes, Array(content[Int(offset)..<Int(offset + length)]), "\(offset)+\(length)")
        }
        out = BytesSink()
        assertFails(try remote.read(model, offset: 0, length: 1_001, to: out))
        assertFails(try remote.read(model, offset: 1_001, length: 0, to: out))
        let weights = try targetAt(source, root, "weights")
        assertFails(try remote.read(weights, offset: 0, length: 1, to: out))
        XCTAssertTrue(out.bytes.isEmpty)
    }

    func testEveryStretchOfASmallFileReadsBackFromAPeer() throws {
        let (_, source, root) = try sampleTree("sync-every-stretch")
        let shard = try targetAt(source, root, "weights/shards/a.bin")
        let content = corpusBytes("shard-a", 100)
        let remote = try Remote(peer: TestPeer(source), root: root)
        for offset in 0..<100 {
            for length in 1...(100 - offset) {
                let out = BytesSink()
                try remote.read(shard, offset: UInt64(offset), length: UInt64(length), to: out)
                XCTAssertEqual(out.bytes, Array(content[offset..<(offset + length)]), "\(offset)+\(length)")
            }
        }
    }

    func testABranchOfAFoldersEntriesIsListed() throws {
        let (_, source, root) = try sampleTree("sync-entries")
        let weights = try targetAt(source, root, "weights")
        let nothing = try targetAt(source, root, "nothing-here")
        let model = try targetAt(source, root, "weights/model.bin")
        let all = try folderOf(source, weights)
        XCTAssertEqual(all.count, 3)
        let remote = try Remote(peer: TestPeer(source), root: root)

        let listed = try remote.entries(weights, start: 0, count: 10)
        XCTAssertEqual([listed.total, listed.start], [3, 0])
        XCTAssertEqual(listed.entries, all.entries)
        let one = try remote.entries(weights, start: 1, count: 1)
        XCTAssertEqual([one.total, one.start], [3, 1])
        XCTAssertEqual(one.entries, Array(all.entries[1..<2]))
        XCTAssertEqual(one.entries.first?.name, "model.bin")
        assertFails(try remote.entries(weights, start: 3, count: 1), "peer")
        let empty = try remote.entries(nothing, start: 0, count: 5)
        XCTAssertEqual(empty.total, 0)
        XCTAssertTrue(empty.entries.isEmpty)
        assertFails(try remote.entries(model, start: 0, count: 1))
        assertFails(try remote.entry(model, name: "x"))
        XCTAssertNil(try remote.entry(nothing, name: "x"))
    }

    func testAPeerSaysWhichChunksItHolds() throws {
        let (_, source, root) = try sampleTree("sync-have")
        let model = try targetAt(source, root, "weights/model.bin")
        let list = try fileOf(source, model)
        for gone in [3, 7, 62] {
            try source.remove(.chunk, list.items[gone].hash)
        }
        let remote = try Remote(peer: TestPeer(source), root: root)
        let map = try remote.have(model)
        XCTAssertEqual([map.count, map.held], [63, 60])
        XCTAssertEqual((0..<63).filter { !map.get($0) }, [3, 7, 62])
        // 63 bits take 8 bytes, after the count.
        XCTAssertEqual(map.encode().count, 16)
    }

    func testATreeGoesThroughABundleAndBack() throws {
        let (temp, source, root) = try sampleTree("sync-bundle")
        let bundle = BytesSink()
        try exportBundle(source, root, to: bundle)
        XCTAssertEqual(Array(bundle.bytes.prefix(8)), Scionic.bundleMagic)
        // Each thing once: 88 frames, each with four bytes for its length.
        let bytesKept = Stored.allCases.reduce(UInt64(0)) { $0 + source.bytes($1) }
        XCTAssertEqual(UInt64(bundle.bytes.count), 8 + bytesKept + 88 * 4 + 87)

        let dest = MemoryStore()
        let summary = try importBundle(dest, root, from: BytesSource(bundle.bytes))
        XCTAssertEqual(summary, try verify(dest, root))
        XCTAssertEqual(try contents(dest), try contents(source))
        // Into a store that holds it all already: nothing is kept twice.
        try importBundle(dest, root, from: BytesSource(bundle.bytes))
        XCTAssertEqual(try contents(dest), try contents(source))

        // A bundle as a file on disk.
        let path = temp.join("tree.bundle")
        try exportBundle(source, root, to: createFileAt(path))
        let fromDisk = MemoryStore()
        try importBundle(fromDisk, root, from: openFileAt(path))
        XCTAssertEqual(try contents(fromDisk), try contents(source))

        // A bundle that stops early leaves a tree that is not whole, and says so.
        for cut in [0, 7, 8, 9, 200, bundle.bytes.count - 1] {
            assertFails(try importBundle(MemoryStore(), root, from: BytesSource(Array(bundle.bytes[..<cut]))), nil, "cut at \(cut)")
        }
        // A stream that is no bundle.
        var other = bundle.bytes
        other[0] ^= 1
        assertFails(try importBundle(MemoryStore(), root, from: BytesSource(other)))
        // A bundle of one tree is not taken for another.
        let wrong = Root.of(record: bytes("another tree"))
        assertFails(try importBundle(MemoryStore(), wrong, from: BytesSource(bundle.bytes)), "hashMismatch")
    }

    func testAResponderSaysWhatItDoesNotHoldAndWhatLiesOutside() throws {
        let (_, source, root) = try sampleTree("sync-refusals")
        let model = try targetAt(source, root, "weights/model.bin")
        let weights = try targetAt(source, root, "weights")
        let unknown = Hash.of(bytes("nobody holds this"))
        let responder = Responder(source)
        func answer(_ request: Request) throws -> [[UInt8]] {
            var frames: [[UInt8]] = []
            try responder.answer(request.encode()) { frames.append($0) }
            return frames
        }
        func refused(_ request: Request, _ why: Refusal) throws {
            let frames = try answer(request)
            XCTAssertEqual(frames.count, 1, "\(request)")
            XCTAssertEqual(try Frame(decoding: frames[0]), .refused(why), "\(request)")
        }
        let notHeld: [Request] = [
            .record(Root(hash: unknown)),
            .folder(unknown),
            .file(unknown),
            .chunk(unknown),
            .have(unknown),
            .folderBranch(folder: unknown, start: 0, count: 1),
            .folderName(folder: unknown, name: "a"),
            .fileBranch(file: unknown, start: 0, count: 1),
            .fileBytes(file: unknown, offset: 0, length: 1),
            .chunks(file: unknown, start: 0, count: 1),
            // A folder is not found as a file, nor a file as a folder.
            .file(weights.hash),
            .folder(model.hash),
        ]
        for request in notHeld {
            try refused(request, .notHeld)
        }
        let outside: [Request] = [
            .folderBranch(folder: weights.hash, start: 3, count: 1),
            .fileBranch(file: model.hash, start: 63, count: 1),
            .fileBytes(file: model.hash, offset: 1_000, length: 1),
            .chunks(file: model.hash, start: 63, count: 1),
        ]
        for request in outside {
            try refused(request, .outOfRange)
        }

        // What reaches past the end is cut off at the end.
        XCTAssertEqual(try answer(.chunks(file: model.hash, start: 60, count: 10)).count, 3)
        let frames = try answer(.fileBytes(file: model.hash, offset: 990, length: 10_000))
        guard case let .fileBranch(branch) = try Frame(decoding: frames[0]) else {
            return XCTFail("no branch")
        }
        XCTAssertEqual(branch.start, 61)
        XCTAssertEqual(branch.items.count, 2)
        XCTAssertEqual(try branch.check(file: model, chunking: nil), 976)

        // Chunks come in order, up to the first one that is not held.
        try source.remove(.chunk, fileOf(source, model).items[12].hash)
        let some = try answer(.chunks(file: model.hash, start: 10, count: 5))
        XCTAssertEqual(some.count, 3)
        XCTAssertEqual(some.first?.first, FrameTag.chunk)
        XCTAssertEqual(some.dropFirst().first?.first, FrameTag.chunk)
        XCTAssertEqual(try Frame(decoding: some[2]), .refused(.notHeld))

        // A request that is malformed is an error, and gets no frame.
        var count = 0
        for request: [UInt8] in [[], [0x30], [UInt8](repeating: 0x3A, count: 33), [UInt8](repeating: 0x37, count: 44)] {
            assertFails(try responder.answer(request) { _ in count += 1 })
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(weights.kind, .folder)
    }
}
