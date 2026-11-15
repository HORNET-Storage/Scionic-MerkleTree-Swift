// What a forger can try, and that each try is refused.
//
// The forger here is a peer that answers a receiver, a bundle that a receiver
// reads, or whoever wrote into a receiver's store. Each test makes the forgery
// out of bytes, as a forger would, and holds the receiver to two things: it says
// no, and it has kept nothing that is not a true part of the tree it asked for.

import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Everything a store holds has to be what its hash says it is.
func assertClean(_ store: MemoryStore, file: StaticString = #filePath, line: UInt = #line) throws {
    for kind in Stored.allCases {
        for hash in store.hashes(kind) {
            let bytes = try kept(store, kind, hash)
            switch kind {
            case .chunk:
                XCTAssertEqual(Hash.of(bytes), hash, file: file, line: line)
            case .fileList:
                XCTAssertEqual(try FileList(decoding: bytes).hash, hash, file: file, line: line)
            case .folderList:
                XCTAssertEqual(try FolderList(decoding: bytes).hash, hash, file: file, line: line)
            case .record:
                XCTAssertEqual(Root.of(record: bytes).hash, hash, file: file, line: line)
                _ = try Record(decoding: bytes)
            }
        }
    }
}

/// Everything `dest` holds has to be a part of what `source` holds.
func assertOnlyFrom(_ dest: MemoryStore, _ source: MemoryStore, file: StaticString = #filePath, line: UInt = #line) throws {
    try assertClean(dest, file: file, line: line)
    let honest = Set(try contents(source))
    for thing in try contents(dest) {
        XCTAssertTrue(honest.contains(thing), "\(thing.prefix(80)) was kept", file: file, line: line)
    }
}

/// Fetches a tree from a peer that changes its answers on the way.
func fetchTampered(
    _ source: MemoryStore,
    _ root: Root,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ tamper: @escaping ([UInt8], [[UInt8]]) -> [[UInt8]]
) throws -> (result: Result<Summary, any Error>, dest: MemoryStore) {
    let dest = MemoryStore()
    let result = Result { try fetch(dest, root, from: TestPeer(source, tamper: tamper)) }
    try assertOnlyFrom(dest, source, file: file, line: line)
    return (result, dest)
}

/// The error that a result holds, as an error of this library.
func failure<T>(_ result: Result<T, any Error>) -> ScionicError? {
    if case let .failure(error) = result {
        return error as? ScionicError
    }
    return nil
}

private func oracleEntry(_ entry: Entry) -> Oracle.Entry {
    Oracle.Entry(kind: entry.kind == .file ? 1 : 2, size: entry.size, hash: entry.hash.bytes, name: entry.nameBytes)
}

final class ForgeryTests: XCTestCase {
    func testAnyChangedByteOfAnyFrameIsRefused() throws {
        let (_, source, root) = try sampleTree("forge-any-byte")
        for target in 0..<88 {
            for place in 0..<3 {
                var seen = 0
                let (result, dest) = try fetchTampered(source, root) { _, frames in
                    var frames = frames
                    for index in frames.indices {
                        if seen == target {
                            let at = [0, frames[index].count / 2, frames[index].count - 1][place]
                            frames[index][at] ^= 1
                        }
                        seen += 1
                    }
                    return frames
                }
                XCTAssertNotNil(failure(result), "frame \(target), place \(place)")
                assertFails(try verify(dest, root))
            }
        }
    }

    func testEveryByteOfABranchIsCoveredByTheHashItIsHeldAgainst() throws {
        // A branch shows a part of a list, and carries nodes for the rest. If one
        // of its bytes could change and the branch still pass, two different
        // branches would show the same thing, and that byte would be nobody's to
        // vouch for. So every byte of every branch of a list of nine is changed
        // here, one at a time, in its lowest bit and in its highest.
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let file = try builder.file(bytes: corpusBytes("covered", 9 * 16))
        let folder = try builder.folder((0..<9).map { try Entry(name: "n\(padded($0, 2))", target: file) })
        let fileList = try fileOf(store, file)
        let folderList = try folderOf(store, folder)
        XCTAssertEqual([fileList.count, folderList.count], [9, 9])
        func eachChange(_ branch: [UInt8], _ what: String, _ taken: ([UInt8]) -> Bool) {
            XCTAssertTrue(taken(branch), "\(what): as it was made")
            for at in branch.indices {
                for bit: UInt8 in [0x01, 0x80] {
                    var changed = branch
                    changed[at] ^= bit
                    XCTAssertFalse(taken(changed), "\(what): byte \(at) of \(branch.count)")
                }
            }
        }
        for start: UInt64 in 0..<9 {
            for end in (start + 1)...9 {
                eachChange(try folderList.open(start: start, end: end).encode(), "entries \(start)..\(end)") { bytes in
                    passes { try FolderBranch(decoding: bytes).check(folder: folder) }
                }
                eachChange(try fileList.open(start: start, end: end).encode(), "chunks \(start)..\(end)") { bytes in
                    passes { try FileBranch(decoding: bytes).check(file: file, chunking: nil) }
                }
            }
        }
        // The answer to a name is a branch too, whether the name is there or not.
        for name in ["n00", "n04", "n08", "a", "n04x", "z"] {
            eachChange(try folderList.openName(name).encode(), "the answer for \(name)") { bytes in
                // Taken whether it shows the entry or proves the name is not there.
                passes { try FolderBranch(decoding: bytes).check(folder: folder, name: name) }
            }
        }
    }

    func testAMadeUpChildUnderAFolderOrAFileIsRefused() throws {
        let (_, source, root) = try sampleTree("forge-child")
        let weights = try targetAt(source, root, "weights")
        let model = try targetAt(source, root, "weights/model.bin")
        let madeUp = Oracle.Entry.file("zz-made-up", Oracle.sha(bytes("made up")), 7)
        let madeUpItem = Oracle.Item.of(bytes("a made-up chunk"))

        // One more entry at the end of a folder's list, one more item at the end
        // of a file's list, and one less of each.
        let moreEntries = madeUp.bytes
        let moreItems = madeUpItem.bytes
        let forges: [(String, ([UInt8]) -> [UInt8]?)] = [
            ("an entry more", { frame in frame[0] == FrameTag.folderList ? frame + moreEntries : nil }),
            ("an item more", { frame in frame[0] == FrameTag.fileList && frame.count > 1 ? frame + moreItems : nil }),
            ("an entry less", { frame in
                guard frame[0] == FrameTag.folderList,
                      let list = try? FolderList(decoding: Array(frame[1...])),
                      !list.entries.isEmpty,
                      let shorter = try? FolderList(entries: Array(list.entries.dropLast()))
                else {
                    return nil
                }
                return Oracle.frame(FrameTag.folderList, shorter.encode())
            }),
            ("an item less", { frame in frame[0] == FrameTag.fileList && frame.count > 37 ? Array(frame.dropLast(36)) : nil }),
        ]
        for (what, forge) in forges {
            var done = false
            let (result, _) = try fetchTampered(source, root) { _, frames in
                frames.map { frame in
                    if !done, let forged = forge(frame) {
                        done = true
                        return forged
                    }
                    return frame
                }
            }
            // It is refused as something nothing names, or sooner, by its length:
            // a file's list may be no longer than the file's size allows.
            XCTAssertTrue(["notWanted", "limitExceeded"].contains(failure(result)?.caseName ?? ""), "\(what): \(result)")
        }

        // A part of the folder, from a peer that has made up a folder of four
        // entries which holds the three real ones. It is whole and well formed. It
        // is another folder, and the receiver asked about this one.
        let four = try folderOf(source, weights).entries.map(oracleEntry) + [madeUp]
        for (start, end) in [(0, 4), (3, 4), (0, 1)] {
            guard case let .folderBranch(branch) = try Frame(decoding: Oracle.folderBranchFrame(four, start, end)) else {
                return XCTFail("no branch")
            }
            assertFails(try branch.check(folder: weights), nil, "\(start)..\(end)")
            assertFails(try branch.check(folder: weights, name: "zz-made-up"))
        }
        let peer = TestPeer(source) { request, frames in
            request[0] == 0x33 ? [Oracle.folderBranchFrame(four, 3, 4)] : frames
        }
        let remote = try Remote(peer: peer, root: root)
        assertFails(try remote.entry(weights, name: "zz-made-up"))
        assertFails(try remote.lookup("weights/zz-made-up"))

        // The same for a file: a made-up list of 64 chunks that holds the real 63
        // is another file.
        let longer = try fileOf(source, model).items.map { Oracle.Item(hash: $0.hash.bytes, length: $0.length) } + [madeUpItem]
        for (start, end) in [(0, 64), (63, 64), (5, 6)] {
            let branch = try FileBranch(decoding: Array(Oracle.fileBranchFrame(longer, start, end)[1...]))
            assertFails(try branch.check(file: model, chunking: nil), nil, "\(start)..\(end)")
        }
    }

    func testARealChildsBranchDoesNotCarryAnotherChild() throws {
        let (_, source, root) = try sampleTree("forge-branch")
        let weights = try targetAt(source, root, "weights")
        let model = try targetAt(source, root, "weights/model.bin")
        let list = try folderOf(source, weights)
        let modelPlace = list.placeOf("model.bin")
        let honestBranch = try list.openName("model.bin")
        XCTAssertEqual(try honestBranch.check(folder: weights, name: "model.bin")?.name, "model.bin")
        let honest = honestBranch.encode()

        // The entry that is shown starts 20 bytes into the branch: its kind, its
        // size, its hash, and then its name.
        func with(_ at: Int, _ value: UInt8) throws {
            var forged = honest
            forged[at] = value
            _ = try FolderBranch(decoding: forged).check(folder: weights, name: "model.bin")
        }
        assertFails(try with(20, 2), nil, "the file shown as a folder")
        assertFails(try with(28, honest[28] ^ 1), nil, "another size")
        assertFails(try with(29, honest[29] ^ 1), nil, "another hash")
        assertFails(try with(60, honest[60] ^ 1), nil, "another hash")
        assertFails(try with(63, UInt8(ascii: "n")), nil, "another name")
        assertFails(try with(15, honest[15] ^ 1), nil, "another place")
        assertFails(try with(7, honest[7] &+ 1), nil, "another count")

        // The neighbour's branch, with the neighbour passed off under the name
        // that was asked for, and the branch of the wrong place as proof that the
        // name is not there.
        let entries = list.entries.map(oracleEntry)
        let leaves = Oracle.folderLeaves(entries)
        let record = try kept(source, .record, root.hash)
        for place in 0..<3 {
            for name in ["model.bin", "copy-of-model.bin", "shards", "absent", "a", "zz"] {
                // As the place really is: right only when it is the name's place.
                let plain = Oracle.folderBranchFrame(entries, place, place + 1)
                // With the entry renamed to what was asked for.
                var renamed = entries[place]
                renamed.name = Array(name.utf8)
                let passedOff = Oracle.folderBranchFrameAs(3, UInt64(place), [renamed], leaves.carried(place, place + 1))
                let truth = list.get(name)
                for (forged, isPlain) in [(plain, true), (passedOff, false)] {
                    let peer = ScriptedPeer { request in
                        request[0] == 0x30 ? [record] : [forged]
                    }
                    let remote = try Remote(peer: peer, root: root)
                    let atItsPlace = list.placeOf(name) == UInt64(place)
                    let honestAnswer = isPlain && atItsPlace
                    let unchanged = !isPlain && entries[place].name == Array(name.utf8)
                    if honestAnswer || (unchanged && atItsPlace) {
                        XCTAssertEqual(try remote.entry(weights, name: name), truth, "\(name) at \(place)")
                    } else {
                        assertFails(try remote.entry(weights, name: name), nil, "\(name) at \(place), plain: \(isPlain)")
                    }
                }
            }
        }
        XCTAssertEqual(modelPlace, 1)

        // A file's branch with one item changed, and the branch of other chunks
        // than those that hold the bytes asked for.
        let fileList = try fileOf(source, model)
        let branch = try fileList.open(start: 6, end: 9).encode()
        XCTAssertEqual(try FileBranch(decoding: branch).check(file: model, chunking: nil), 96)
        for at in [20, 51, 52, 55] {
            var forged = branch
            forged[at] ^= 1
            assertFails(try FileBranch(decoding: forged).check(file: model, chunking: nil), nil, "byte \(at)")
        }
        let elsewhere = Oracle.frame(FrameTag.fileBranch, try fileList.open(start: 0, end: 3).encode())
        let peer = TestPeer(source) { request, frames in
            request[0] == 0x36 ? [elsewhere] : frames
        }
        let remote = try Remote(peer: peer, root: root)
        let out = BytesSink()
        assertFails(try remote.read(model, offset: 100, length: 40, to: out), "notWanted")
        XCTAssertTrue(out.bytes.isEmpty)
    }

    func testAFileIsNeverTakenForAFolderNorAListForAChunk() throws {
        let (_, source, root) = try sampleTree("forge-kinds")
        let weights = try targetAt(source, root, "weights")
        let model = try targetAt(source, root, "weights/model.bin")
        let fileFrame = Oracle.frame(FrameTag.fileList, try kept(source, .fileList, model.hash))
        let folderFrame = Oracle.frame(FrameTag.folderList, try kept(source, .folderList, weights.hash))
        let chunk = Oracle.frame(FrameTag.chunk, corpusBytes("model", 16))

        // Each kind of question, answered with a true part of the tree that is of
        // another kind.
        for (asked, answers): (UInt8, [[UInt8]]) in [(0x31, [fileFrame, chunk]), (0x34, [folderFrame, chunk]), (0x37, [fileFrame, folderFrame])] {
            for answer in answers {
                var done = false
                let (result, _) = try fetchTampered(source, root) { request, frames in
                    if request[0] == asked && !done {
                        done = true
                        return [answer]
                    }
                    return frames
                }
                XCTAssertNotNil(failure(result), "\(asked)")
            }
        }

        // A file's entry, shown as a folder's: the kind is part of the entry.
        let top = try recordOf(source, root).top
        var flipped = try kept(source, .folderList, top.hash)
        let list = try folderOf(source, top)
        let before = list.entries[0].encodedCount
        XCTAssertEqual(list.entries[1].name, "empty.bin")
        XCTAssertEqual(flipped[before], 1)
        flipped[before] = 2
        XCTAssertNoThrow(try FolderList(decoding: flipped))
        let flippedFrame = Oracle.frame(FrameTag.folderList, flipped)
        let (result, _) = try fetchTampered(source, root) { request, frames in
            request[0] == 0x31 ? [flippedFrame] : frames
        }
        XCTAssertEqual(failure(result)?.caseName, "notWanted")

        // A file whose bytes are another file's list, to the letter. It is kept as
        // a chunk, under the plain hash of its bytes, and never as a list.
        let listBytes = try kept(source, .fileList, model.hash)
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: try .fixed(4096))
        let odd = try builder.file(bytes: listBytes)
        let oddRoot = try builder.finish(top: odd)
        let dest = MemoryStore()
        try fetch(dest, oddRoot, from: TestPeer(store))
        let plain = Hash.of(listBytes)
        XCTAssertTrue(try dest.has(.chunk, plain))
        XCTAssertFalse(try dest.has(.fileList, plain))
        XCTAssertFalse(try dest.has(.fileList, model.hash))
        XCTAssertNotEqual(plain, model.hash)
    }

    func testAFileIsNotGivenAnotherFilesChunks() throws {
        let (_, source, root) = try sampleTree("forge-chunks")
        let model = try targetAt(source, root, "weights/model.bin")
        let shard = try targetAt(source, root, "weights/shards/a.bin")
        let shardChunks = try fileOf(source, shard).items.map { Oracle.frame(FrameTag.chunk, try kept(source, .chunk, $0.hash)) }

        // A whole fetch: the chunks of one file, sent when another file's were
        // asked for. They are true chunks of the tree, and they are not what was
        // asked for.
        let (result, _) = try fetchTampered(source, root) { request, frames in
            if case let .chunks(file, _, _)? = try? Request(decoding: request), file == model.hash {
                return shardChunks
            }
            return frames
        }
        XCTAssertEqual(failure(result)?.caseName, "notWanted")

        // A stretch of one file, answered with another file's chunks, and with the
        // file's own chunks in another order.
        for swap in [false, true] {
            let peer = TestPeer(source) { request, frames in
                if request[0] != 0x37 {
                    return frames
                }
                if swap {
                    var frames = frames
                    frames.swapAt(0, 1)
                    return frames
                }
                return shardChunks
            }
            let remote = try Remote(peer: peer, root: root)
            let out = BytesSink()
            assertFails(try remote.read(model, offset: 0, length: 64, to: out), nil, "swap: \(swap)")
            XCTAssertTrue(out.bytes.isEmpty, "no byte of another chunk is handed out")
        }

        // A stretch of one file, answered with the branch of another file's list.
        let otherBranch = Oracle.frame(FrameTag.fileBranch, try fileOf(source, shard).open(start: 0, end: 4).encode())
        let peer = TestPeer(source) { request, frames in
            request[0] == 0x36 ? [otherBranch] : frames
        }
        let remote = try Remote(peer: peer, root: root)
        let out = BytesSink()
        assertFails(try remote.read(model, offset: 0, length: 64, to: out))
        XCTAssertTrue(out.bytes.isEmpty)
    }

    func testARecordForAnotherRootIsRefused() throws {
        let (_, source, root) = try sampleTree("forge-record")
        let builder = Builder(store: source, chunking: smallChunks())
        let other = try builder.finish(top: builder.file(bytes: bytes("another tree")))
        let otherRecord = try kept(source, .record, other.hash)

        let (result, dest) = try fetchTampered(source, root) { request, frames in
            request[0] == 0x30 ? [otherRecord] : frames
        }
        XCTAssertEqual(failure(result)?.caseName, "hashMismatch")
        XCTAssertEqual(try contents(dest), [], "nothing is kept")

        assertFails(try Remote(peer: TestPeer(source) { _, _ in [otherRecord] }, root: root), "hashMismatch")
        // The record that was asked for, with one of its totals changed.
        var changed = try kept(source, .record, root.hash)
        changed[45] ^= 1
        assertFails(try Remote(peer: TestPeer(source) { _, _ in [changed] }, root: root))
    }

    func testNothingIsKeptBeforeItIsTiedToTheRoot() throws {
        let (_, source, root) = try sampleTree("forge-order")
        let top = try recordOf(source, root).top
        let readme = try targetAt(source, root, "readme.txt")
        let shard = try targetAt(source, root, "weights/shards/a.bin")
        let record = try kept(source, .record, root.hash)
        let topList = Oracle.frame(FrameTag.folderList, try kept(source, .folderList, top.hash))
        let readmeList = Oracle.frame(FrameTag.fileList, try kept(source, .fileList, readme.hash))
        let readmeChunk = Oracle.frame(FrameTag.chunk, bytes("a small file"))
        let deepList = Oracle.frame(FrameTag.fileList, try kept(source, .fileList, shard.hash))
        let madeUpChunk = Oracle.frame(FrameTag.chunk, bytes("no part of this tree"))

        let dest = MemoryStore()
        func refused(_ frame: [UInt8], _ what: String) throws {
            let before = try contents(dest)
            assertFails(try Intake(store: dest, root: root).accept(frame), "notWanted", what)
            XCTAssertEqual(try contents(dest), before, "\(what): something was kept")
        }
        func taken(_ frame: [UInt8], _ what: String) throws {
            let intake = try Intake(store: dest, root: root)
            XCTAssertTrue(try intake.accept(frame).kept, what)
            // The same thing again is passed over, and not kept twice.
            let before = try contents(dest)
            XCTAssertFalse(try intake.accept(frame).kept, "\(what), again")
            XCTAssertEqual(try contents(dest), before)
        }

        // Before the record, nothing is tied to anything.
        for (frame, what) in [(topList, "the top folder"), (readmeList, "a file's list"), (readmeChunk, "a chunk")] {
            try refused(frame, what)
        }
        XCTAssertNil(try Intake(store: dest, root: root).record)
        try taken(record, "the record")
        // The record's totals are there to be looked at before anything more is
        // taken.
        let intake = try Intake(store: dest, root: root)
        XCTAssertEqual(intake.record?.totals.chunks, 76)
        XCTAssertEqual(intake.outstanding, 1, "the top folder")

        // After the record, only the top folder is named.
        try refused(readmeList, "a file's list before its folder")
        try refused(readmeChunk, "a chunk before its file's list")
        try refused(deepList, "a list from further down")
        try taken(topList, "the top folder")
        // Now the top folder's files are named, and their chunks are not yet.
        try refused(readmeChunk, "a chunk before its file's list")
        try refused(deepList, "a list from further down")
        try refused(madeUpChunk, "a made-up chunk")
        try taken(readmeList, "a file's list")
        try refused(madeUpChunk, "a made-up chunk")
        try taken(readmeChunk, "a chunk")

        try assertOnlyFrom(dest, source)
        assertFails(try Intake(store: dest, root: root).finish(), "missing")

        // A bundle with a made-up chunk in it is refused where the chunk comes, be
        // the chunk as long as a chunk of this tree or longer.
        let bundle = BytesSink()
        try exportBundle(source, root, to: bundle)
        let shortChunk = Oracle.frame(FrameTag.chunk, bytes("not of this tree"))
        for chunk in [shortChunk, madeUpChunk] {
            let extra = bundle.bytes + u32be(UInt32(chunk.count)) + chunk
            let fresh = MemoryStore()
            assertFails(try importBundle(fresh, root, from: BytesSource(extra)), "notWanted")
            try assertOnlyFrom(fresh, source)
        }
        // And one whose first list comes before its record.
        let early = Array(bundle.bytes[..<8]) + u32be(UInt32(topList.count)) + topList + Array(bundle.bytes[8...])
        let fresh = MemoryStore()
        assertFails(try importBundle(fresh, root, from: BytesSource(early)))
        XCTAssertEqual(try contents(fresh), [])
    }

    func testAPeerWhoseOwnStoreIsWrongIsFoundOut() throws {
        let (_, source, root) = try sampleTree("forge-store")
        let model = try targetAt(source, root, "weights/model.bin")
        let shard = try targetAt(source, root, "weights/shards/a.bin")
        let weights = try targetAt(source, root, "weights")
        let data = try targetAt(source, root, "data")
        let chunk = try fileOf(source, model).items[9]
        let cases: [(Stored, Hash, [UInt8])] = [
            (.chunk, chunk.hash, corpusBytes("wrong", 16)),
            (.fileList, model.hash, try kept(source, .fileList, shard.hash)),
            (.folderList, weights.hash, try kept(source, .folderList, data.hash)),
        ]
        for (kind, hash, wrong) in cases {
            let honest = try kept(source, kind, hash)
            try swapIn(source, kind, hash, wrong)
            // One set of checks: the same forgery is refused in the store that
            // holds it, and by whoever fetches from that store.
            assertFails(try verify(source, root), nil, "\(kind)")
            let dest = MemoryStore()
            assertFails(try fetch(dest, root, from: TestPeer(source)), nil, "\(kind)")
            try assertClean(dest)
            XCTAssertFalse(try dest.has(kind, hash), "\(kind): the forged part was kept")
            try swapIn(source, kind, hash, honest)
        }
        _ = try verify(source, root)
    }

    func testAFileNeverComesBackShort() throws {
        let (_, source, root) = try sampleTree("forge-short")
        let model = try targetAt(source, root, "weights/model.bin")
        let list = try fileOf(source, model)
        let last = list.items[list.items.count - 1]

        // A peer that never sends the file's last chunk.
        var (result, dest) = try fetchTampered(source, root) { _, frames in
            frames.filter { $0[0] != FrameTag.chunk || Hash.of(Array($0[1...])) != last.hash }
        }
        XCTAssertEqual(failure(result)?.caseName, "peer")
        var out = BytesSink()
        assertFails(try readFile(dest, model, to: out), "missing")
        XCTAssertTrue(out.bytes.isEmpty, "an error, and never a shorter file")
        assertFails(try verify(dest, root))

        // The last chunk, one byte short.
        (result, _) = try fetchTampered(source, root) { _, frames in
            frames.map { $0[0] == FrameTag.chunk && Hash.of(Array($0[1...])) == last.hash ? Array($0.dropLast()) : $0 }
        }
        XCTAssertNotNil(failure(result))

        // A chunk that holds nothing, in its place: it is not a chunk at all,
        // whoever takes it, and nothing of a stretch is handed out after it.
        (result, _) = try fetchTampered(source, root) { _, frames in
            frames.map { $0[0] == FrameTag.chunk && Hash.of(Array($0[1...])) == last.hash ? [FrameTag.chunk] : $0 }
        }
        XCTAssertEqual(failure(result)?.caseName, "invalidData")
        let emptied = try Remote(peer: TestPeer(source) { request, frames in request[0] == 0x37 ? [[FrameTag.chunk]] + frames.dropFirst() : frames }, root: root)
        out = BytesSink()
        assertFails(try emptied.read(model, offset: 0, length: 1_000, to: out), "invalidData")
        XCTAssertTrue(out.bytes.isEmpty)

        // A made-up file that is the real one without its last chunk. It is whole
        // and well formed, it is shorter, and it is another file.
        let shorter = list.items.prefix(62).map { Oracle.Item(hash: $0.hash.bytes, length: $0.length) }
        let shorterList = Oracle.frame(FrameTag.fileList, Oracle.fileListBytes(Array(shorter)))
        (result, _) = try fetchTampered(source, root) { request, frames in
            if case let .file(file)? = try? Request(decoding: request), file == model.hash {
                return [shorterList]
            }
            return frames
        }
        XCTAssertEqual(failure(result)?.caseName, "notWanted")
        let shorterBranch = Oracle.fileBranchFrame(Array(shorter), 0, 62)
        var remote = try Remote(peer: TestPeer(source) { request, frames in request[0] == 0x36 ? [shorterBranch] : frames }, root: root)
        out = BytesSink()
        assertFails(try remote.read(model, offset: 0, length: 1_000, to: out))
        XCTAssertTrue(out.bytes.isEmpty)

        // A peer that sends fewer chunks than a stretch needs, and then none.
        var sent = 0
        remote = try Remote(
            peer: TestPeer(source) { request, frames in
                if request[0] != 0x37 {
                    return frames
                }
                let keep = min(frames.count, 3 - sent)
                sent += keep
                return Array(frames.prefix(keep))
            },
            root: root
        )
        out = BytesSink()
        assertFails(try remote.read(model, offset: 0, length: 1_000, to: out), "peer")
        // What was handed out before that is the file's own.
        XCTAssertEqual(out.bytes, Array(corpusBytes("model", 1_000).prefix(out.bytes.count)), "bytes were handed out that are not the file's")
    }

    func testOneNameHasOnePlaceInAFolder() throws {
        // A folder made by an author who put its entries out of order on purpose,
        // with one name twice. The library makes no such folder, so it is hashed
        // here by hand, to the letter of the format.
        for names in [["b", "a", "b", "c"], ["a", "b", "b", "c"], ["c", "b", "a"], ["b", "b"], ["a", "c", "b", "d", "a", "e", "b"]] {
            let entries = names.enumerated().map { place, name in
                Oracle.Entry.file(name, Oracle.sha(bytes("\(name)\(place)")), 1)
            }
            let (folderHash, size) = Oracle.folderHash(entries)
            let folder = Target(kind: .folder, hash: try Hash(bytes: folderHash), size: size)
            let record = Oracle.recordBytes(2, size, folderHash, (0, 0, UInt64(Oracle.folderListBytes(entries).count)), Oracle.chunkingTag("fixed-16"))
            let root = Root.of(record: record)

            // Whole, the list is refused as soon as it is read.
            let whole = Oracle.frame(FrameTag.folderList, Oracle.folderListBytes(entries))
            let dest = MemoryStore()
            let intake = try Intake(store: dest, root: root)
            _ = try intake.accept(record)
            assertFails(try intake.accept(whole), "invalidData", "\(names)")
            XCTAssertEqual(dest.count(.folderList), 0)

            // In part, the author shows whichever place suits him. For each name at
            // most one place is ever accepted, so two entries under one name are
            // never both shown.
            for name in ["a", "b", "c", "d", "e", "f"] {
                var accepted: [(Int, Hash?)] = []
                for shown in entries.indices {
                    let peer = ScriptedPeer { request in
                        request[0] == 0x30 ? [record] : [Oracle.folderBranchFrame(entries, shown, shown + 1)]
                    }
                    let remote = try Remote(peer: peer, root: root)
                    // An answer that the name is not there counts as one too.
                    if let answer = Result(catching: { try remote.entry(folder, name: name) }).ok {
                        accepted.append((shown, answer?.hash))
                    }
                }
                XCTAssertLessThanOrEqual(accepted.count, 1, "\(names): \(name) answered at \(accepted)")
            }

            // A branch of several entries is accepted only where each of them is at
            // its name's one place: never a branch that shows a name twice.
            for start in entries.indices {
                for end in (start + 1)...entries.count {
                    guard case let .folderBranch(branch)? = try? Frame(decoding: Oracle.folderBranchFrame(entries, start, end)) else {
                        continue
                    }
                    if passes({ try branch.check(folder: folder) }) {
                        let shown = branch.entries.map(\.nameBytes)
                        XCTAssertTrue(zip(shown, shown.dropFirst()).allSatisfy { bytesLess($0, $1) }, "\(names) \(start)..\(end)")
                    }
                }
            }
        }
    }

    func testNoPlaceExistsBeyondTheCountAndAForkIsNoLeaf() throws {
        let chunks = (0..<5).map { corpusBytes("p\($0)", 16) }
        let items = chunks.map { Oracle.Item.of($0) }
        let (hash, size) = Oracle.fileHash(items)
        let file = Target(kind: .file, hash: try Hash(bytes: hash), size: size)
        func check(_ frame: [UInt8]) throws -> UInt64 {
            try FileBranch(decoding: Array(frame[1...])).check(file: file, chunking: nil)
        }
        XCTAssertEqual(try check(Oracle.fileBranchFrame(items, 4, 5)), 64)

        // The last chunk, shown again at the place after the last. A tree that
        // fills up a level by repeating its last leaf would take this.
        let carried = Oracle.fileLeaves(items).carried(4, 5)
        for (count, start): (UInt64, UInt64) in [(5, 5), (6, 5), (6, 4), (4, 4), (8, 7)] {
            assertFails(try check(Oracle.fileBranchFrameAs(count, start, Array(items[4...]), carried)), nil, "as \(count) chunks, at \(start)")
        }
        // A file of six chunks whose sixth is the fifth again is another file.
        let six = items + [items[4]]
        XCTAssertNotEqual(Oracle.fileHash(six).hash, hash)
        XCTAssertNotEqual(Oracle.fileLeaves(six).top().hash, Oracle.fileLeaves(items).top().hash)
        for (start, end) in [(0, 6), (5, 6), (4, 5)] {
            assertFails(try check(Oracle.fileBranchFrame(six, start, end)))
        }

        // A fork passed off as a chunk: a file of two "chunks" that are the two
        // forks under the top of a file of four.
        let four = Array(items[..<4])
        let leaves = Oracle.fileLeaves(four)
        let (fourHash, fourSize) = Oracle.fileHash(four)
        let fourFile = Target(kind: .file, hash: try Hash(bytes: fourHash), size: fourSize)
        let forks = [leaves.node(0, 2), leaves.node(2, 2)].map { Oracle.Item(hash: $0.hash, length: UInt32($0.size)) }
        let branch = try FileBranch(decoding: Array(Oracle.fileBranchFrame(forks, 0, 2)[1...]))
        assertFails(try branch.check(file: fourFile, chunking: nil))
        XCTAssertNotEqual(Oracle.fileHash(forks).hash, fourHash)
        // And a leaf passed off as a fork: the top of a file of one chunk is never
        // the top of a file of two.
        XCTAssertNotEqual(Oracle.fileLeaves(Array(items[..<1])).top().hash, Oracle.fileLeaves(Array(items[..<2])).top().hash)
        // The library and the rule written a second time agree on what the honest
        // file is.
        let built = try FileList(decoding: Oracle.fileListBytes(items))
        XCTAssertEqual(built.hash, file.hash)
        XCTAssertEqual(built.target.size, size)
    }

    func testATreeThatHoldsMoreThanItsRecordSaysIsStopped() throws {
        let (_, source, root) = try sampleTree("forge-totals")
        let record = try recordOf(source, root)
        let right = record.totals
        var fewerChunks = right
        fewerChunks.chunks -= 1
        var fewerBytes = right
        fewerBytes.chunkBytes -= 16
        var fewerListBytes = right
        fewerListBytes.listBytes -= 1
        for (field, totals) in [("chunks", fewerChunks), ("chunk bytes", fewerBytes), ("list bytes", fewerListBytes)] {
            let forged = try Record(top: record.top, totals: totals, chunking: record.chunking)
            try source.put(.record, forged.root.hash, forged.encode())
            let dest = MemoryStore()
            if case let .totalsMismatch(named, _, _)? = assertFails(try fetch(dest, forged.root, from: TestPeer(source)), "totalsMismatch", "\(totals)") {
                XCTAssertEqual(named, field)
            }
            try assertClean(dest)
        }
    }

    func testATreeThatIsTooDeepIsRefusedHoweverItArrives() throws {
        let source = MemoryStore()
        let builder = Builder(store: source, chunking: smallChunks())
        let file = try builder.file(bytes: bytes("at the bottom"))
        var inner = try builder.folder([Entry(name: "file", target: file)])
        for _ in 1..<128 {
            inner = try builder.folder([Entry(name: "d", target: inner)])
        }
        let deepestAllowed = try builder.finish(top: inner)
        let totals = try verify(source, deepestAllowed).record.totals

        // One folder more, and a record for it written without the builder.
        let over = try FolderList(entries: [Entry(name: "d", target: inner)])
        try source.put(.folderList, over.hash, over.encode())
        var more = totals
        more.listBytes += over.encodedCount
        let forged = try Record(top: over.target, totals: more, chunking: smallChunks())
        let forgedRoot = forged.root
        try source.put(.record, forgedRoot.hash, forged.encode())

        func tooDeep(_ error: ScionicError?) {
            if case .tooDeep(128)? = error {
                return
            }
            XCTFail("\(String(describing: error))")
        }
        tooDeep(assertFails(try verify(source, forgedRoot)))
        tooDeep(assertFails(try fetch(MemoryStore(), forgedRoot, from: TestPeer(source))))
        let bundle = BytesSink()
        try exportBundle(source, forgedRoot, to: bundle)
        tooDeep(assertFails(try importBundle(MemoryStore(), forgedRoot, from: BytesSource(bundle.bytes))))
        let temp = try TempDir("forge-deep")
        tooDeep(assertFails(try writeToDisk(source, forgedRoot, to: temp.join("never-written"))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.join("never-written")))
        tooDeep(assertFails(try lookup(source, forgedRoot, path: Array(repeating: "d", count: 130).joined(separator: "/"))))

        // The deepest tree that a tree may be is taken, and found to its bottom.
        try fetch(MemoryStore(), deepestAllowed, from: TestPeer(source))
        XCTAssertNotNil(try lookup(source, deepestAllowed, path: String(repeating: "d/", count: 127) + "file"))
    }

    func testMalformedInputIsAnErrorAndNeverACrash() throws {
        let (_, source, root) = try sampleTree("forge-malformed")
        let top = try recordOf(source, root).top
        let model = try targetAt(source, root, "weights/model.bin")
        let weights = try targetAt(source, root, "weights")
        let record = try kept(source, .record, root.hash)
        let honest: [[UInt8]] = [
            record,
            Oracle.frame(FrameTag.folderList, try kept(source, .folderList, top.hash)),
            Oracle.frame(FrameTag.fileList, try kept(source, .fileList, model.hash)),
            Oracle.frame(FrameTag.chunk, bytes("a small file")),
            Oracle.frame(FrameTag.fileBranch, try fileOf(source, model).open(start: 3, end: 9).encode()),
            Oracle.frame(FrameTag.folderBranch, try folderOf(source, weights).open(start: 1, end: 2).encode()),
            Oracle.frame(0x26, [0, 0, 0, 0, 0, 0, 0, 9, 0xFF, 0x80]),
            [0x27, 1],
        ]
        XCTAssertEqual(honest[0][0], FrameTag.record)
        // Every one of them reads, as it is.
        for frame in honest {
            XCTAssertNoThrow(try Frame(decoding: frame), "\(frame.prefix(1))")
        }

        // Every way of cutting a frame short, and every single byte of it changed
        // in three ways.
        var forged: [[UInt8]] = []
        for frame in honest {
            let step = max(frame.count / 400, 1)
            for cut in stride(from: 0, to: frame.count, by: step) {
                forged.append(Array(frame[..<cut]))
            }
            for at in stride(from: 0, to: frame.count, by: step) {
                for change: UInt8 in [1, 0x80, 0xFF] {
                    var changed = frame
                    changed[at] ^= change
                    forged.append(changed)
                }
            }
            forged.append(frame + [0])
        }
        // And bytes that are nothing at all.
        for length in [1, 2, 20, 36, 37, 45, 66, 100, 500] {
            for seed in 0..<8 {
                for tag: UInt8 in [0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x30, 0x33, 0x36, 0xFF] {
                    var noise = corpusBytes("noise-\(seed)", length)
                    noise[0] = tag
                    forged.append(noise)
                }
            }
        }

        let responder = Responder(source)
        let dest = MemoryStore()
        _ = try Intake(store: dest, root: root).accept(record)
        for frame in forged {
            // None of these may crash, whatever they are given. What they answer is
            // held to account by the tests beside this one.
            _ = try? Frame(decoding: frame)
            _ = try? Request(decoding: frame)
            _ = try? Record(decoding: frame)
            _ = try? FileList(decoding: frame)
            _ = try? FolderList(decoding: frame)
            _ = try? OpenFile(decoding: frame)
            _ = try? OpenFolder(decoding: frame)
            _ = try? HaveMap(decoding: frame)
            if let branch = try? FileBranch(decoding: frame) {
                _ = try? branch.check(file: model, chunking: nil)
                _ = try? branch.check(file: model, chunking: smallChunks())
            }
            if let branch = try? FolderBranch(decoding: frame) {
                _ = try? branch.check(folder: weights)
                _ = try? branch.check(folder: weights, name: "model.bin")
            }
            _ = try? Root(text: String(decoding: frame, as: UTF8.self))
            _ = try? Chunking(tag: frame)
            _ = try? checkName(String(decoding: frame, as: UTF8.self))
            _ = try? responder.answer(frame) { _ in }
            _ = try? Intake(store: dest, root: root).accept(frame)
            let bundle = Scionic.bundleMagic + u32be(UInt32(frame.count)) + frame
            _ = try? importBundle(MemoryStore(), root, from: BytesSource(bundle))
            _ = try? importBundle(MemoryStore(), root, from: BytesSource(frame))
            _ = try? readFrame(BytesSource(frame), limit: 1 << 20)
            _ = try? serve(source, from: BytesSource(frame), to: BytesSink())
            _ = try? serve(source, from: BytesSource(u32be(UInt32(frame.count)) + frame), to: BytesSink())
        }
        XCTAssertGreaterThan(forged.count, 5_000)
        // Whatever got through was a true part of the tree.
        try assertOnlyFrom(dest, source)
        _ = try verify(source, root)
    }
}
