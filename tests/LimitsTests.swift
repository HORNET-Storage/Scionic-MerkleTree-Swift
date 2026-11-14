// How much a receiver sets aside for a peer: no more than the tree it trusts
// calls for. And an intake that has refused a part of its tree does not go on
// as if nothing had happened.

import XCTest
@testable import ScionicMerkleTree

/// A tree that is wrong in itself: two of its files list the same chunk, the one
/// with 16 bytes and the other with 15. Every list of it is well formed and has
/// the hash its parent gives it.
private func treeWithAChunkOfTwoLengths() throws -> (record: Record, folder: FolderList, right: FileList, wrong: FileList, whole: [UInt8]) {
    let whole = corpusBytes("whole", 16)
    let item = try ChunkRef.of(whole)
    let right = try FileList(items: [item])
    let wrong = try FileList(items: [ChunkRef(hash: item.hash, length: 15)])
    let folder = try FolderList(entries: [Entry(name: "a", target: right.target), Entry(name: "b", target: wrong.target)])
    let totals = Totals(chunks: 1, chunkBytes: 16, listBytes: 72 + folder.encodedCount)
    let record = try Record(top: folder.target, totals: totals, chunking: smallChunks())
    return (record, folder, right, wrong, whole)
}

final class LimitsTests: XCTestCase {
    func testEveryRequestSaysHowLongItsAnswerMayBe() throws {
        let (_, source, root) = try sampleTree("limits-fetch")
        let peer = TestPeer(source)
        try fetch(MemoryStore(), root, from: peer)
        let listBytes = Int(try recordOf(source, root).totals.listBytes)
        XCTAssertEqual(peer.wire.requests.count, peer.wire.limits.count)
        for (request, limit) in zip(peer.wire.requests, peer.wire.limits) {
            switch try Request(decoding: request) {
            case .record:
                XCTAssertEqual(limit, Scionic.maxRecordBytes)
            case .folder:
                // A folder's list: no longer than the record leaves room for.
                XCTAssertLessThanOrEqual(limit, listBytes + 1)
            case let .file(file):
                // A file's list: no longer than the file's size allows. These files
                // are split into chunks of 16 bytes, so it is known exactly.
                XCTAssertEqual(limit, max(try kept(source, .fileList, file).count + 1, 2))
            case .chunks:
                // A chunk: no longer than the tree's way of chunking allows.
                XCTAssertEqual(limit, 17)
            case let other:
                XCTFail("\(other)")
            }
        }
    }

    func testAnAnswerThatIsTooLongIsRefusedByItsLength() throws {
        let (_, source, root) = try sampleTree("limits-long")
        let honest = Set(try contents(source))
        // The first answer to each kind of request, with bytes added to it. A
        // connection refuses such a frame by the length that comes before it.
        for asked: UInt8 in [0x30, 0x31, 0x34, 0x37] {
            var done = false
            let dest = MemoryStore()
            let peer = TestPeer(source) { request, frames in
                var frames = frames
                if request[0] == asked && !done {
                    done = true
                    frames[0] += [UInt8](repeating: 0, count: 40_000)
                }
                return frames
            }
            assertFails(try fetch(dest, root, from: peer), "limitExceeded", "\(asked)")
            for thing in try contents(dest) {
                XCTAssertTrue(honest.contains(thing), "\(asked)")
            }
        }

        // The same for one who reads parts of a tree and keeps nothing.
        let weights = try targetAt(source, root, "weights")
        let model = try targetAt(source, root, "weights/model.bin")
        for asked: UInt8 in [0x30, 0x32, 0x33, 0x36, 0x37, 0x39] {
            let peer = TestPeer(source) { request, frames in
                var frames = frames
                if request[0] == asked {
                    frames[0] += [UInt8](repeating: 0, count: 200_000)
                }
                return frames
            }
            assertFails(
                try {
                    let remote = try Remote(peer: peer, root: root)
                    _ = try remote.entries(weights, start: 0, count: 2)
                    _ = try remote.entry(weights, name: "model.bin")
                    try remote.read(model, offset: 100, length: 300, to: BytesSink())
                    _ = try remote.have(model)
                }(),
                "limitExceeded",
                "\(asked)"
            )
        }
        // What such a reader lets through for a stretch of a file is small: the
        // branch of the list that holds the stretch, and chunks no longer than the
        // branch says they are.
        let peer = TestPeer(source)
        let remote = try Remote(peer: peer, root: root)
        try remote.read(model, offset: 100, length: 300, to: BytesSink())
        _ = try remote.have(model)
        let limits = peer.wire.limits
        // 300 bytes lie in 20 chunks of 16 bytes at the most, the two at the ends
        // counted: 23 bytes, 20 items, and 80 nodes of 40 bytes.
        XCTAssertEqual(limits[1], 23 + 20 * 36 + 80 * 40)
        XCTAssertEqual(limits[2], 17)
        // 63 chunks are 63 bits: 8 bytes, after the frame's first byte and the
        // count.
        XCTAssertEqual(limits[3], 17)
    }

    func testALongFrameThatNeverComesCostsLittle() throws {
        // A stream that claims a frame of 3 GiB and holds five bytes of it. The
        // frame's bytes are set aside as they come, so this is an error at once,
        // and not three gigabytes of memory first.
        let stream = u32be(3 << 30) + bytes("short")
        assertFails(try readFrame(BytesSource(stream), limit: .max), "invalidData")
        // Under a limit it is refused by its length, with nothing of it read.
        let unread = BytesSource(stream)
        assertFails(try readFrame(unread, limit: 1 << 20), "limitExceeded")
        XCTAssertEqual(unread.left, 5)

        // A frame that spans several steps of setting aside comes back whole.
        let long = corpusBytes("long", (3 << 20) + 7)
        let input = BytesSource(u32be(UInt32(long.count)) + long, awkward: true)
        XCTAssertEqual(try readFrame(input, limit: long.count), long)
        XCTAssertNil(try readFrame(input, limit: 1))
        // A length of zero is no frame.
        assertFails(try readFrame(BytesSource([0, 0, 0, 0]), limit: 100))
        // A stream that ends inside the length.
        assertFails(try readFrame(BytesSource([0, 0]), limit: 100))
    }

    func testAnIntakeThatRefusedAPartOfItsTreeIsDone() throws {
        let tree = try treeWithAChunkOfTwoLengths()
        let root = tree.record.root
        let dest = MemoryStore()
        let intake = try Intake(store: dest, root: root)
        _ = try intake.accept(tree.record.encode())

        // A frame that is refused at the door leaves the intake as it was.
        assertFails(try intake.accept(chunkFrame(bytes("nothing names this"))), "notWanted")
        assertFails(try intake.accept([0x25]))
        _ = try intake.accept(folderListFrame(tree.folder.encode()))
        _ = try intake.accept(fileListFrame(tree.right.encode()))

        // The second list is named, and it is what its hash says. It fails a check
        // all the same, and that shows the tree itself to be wrong.
        assertFails(try intake.accept(fileListFrame(tree.wrong.encode())), "sizeMismatch")
        XCTAssertFalse(try dest.has(.fileList, tree.wrong.hash), "a list that failed its checks is not kept")
        // From here on the intake takes nothing, asks for nothing, and never says
        // that the tree is whole.
        assertFails(try intake.accept(chunkFrame(tree.whole)), "intakeFailed")
        assertFails(try intake.accept(fileListFrame(tree.right.encode())), "intakeFailed")
        XCTAssertTrue(intake.requests(limit: 10).isEmpty)
        assertFails(try intake.finish(), "intakeFailed")
        XCTAssertFalse(try dest.has(.chunk, ChunkRef.of(tree.whole).hash))

        // A new intake goes on from what the store holds, and finds the same.
        let again = try Intake(store: dest, root: root)
        XCTAssertEqual(again.outstanding, 2, "one list and one chunk")
        assertFails(try again.accept(fileListFrame(tree.wrong.encode())))
        assertFails(try again.finish(), "intakeFailed")

        // And so does one that is given the lists the other way round.
        let fresh = MemoryStore()
        let other = try Intake(store: fresh, root: root)
        _ = try other.accept(tree.record.encode())
        _ = try other.accept(folderListFrame(tree.folder.encode()))
        _ = try other.accept(fileListFrame(tree.wrong.encode()))
        assertFails(try other.accept(fileListFrame(tree.right.encode())))
        XCTAssertFalse(try fresh.has(.fileList, tree.right.hash))
        assertFails(try other.finish(), "intakeFailed")
    }

    func testATreeNeverTakesMoreRoomThanItsRecordSays() throws {
        let (_, source, root) = try sampleTree("limits-room")
        let record = try recordOf(source, root)
        let right = record.totals
        // Records that say less than the tree holds: of lists, of chunks, and of
        // the chunks' bytes.
        var fewerListBytes = right
        fewerListBytes.listBytes -= 1
        var fewerChunks = right
        fewerChunks.chunks -= 1
        var fewerChunkBytes = right
        fewerChunkBytes.chunkBytes -= 1
        for totals in [fewerListBytes, fewerChunks, fewerChunkBytes] {
            let forged = try Record(top: record.top, totals: totals, chunking: record.chunking)
            try source.put(.record, forged.root.hash, forged.encode())
            let dest = MemoryStore()
            assertFails(try fetch(dest, forged.root, from: TestPeer(source)), "totalsMismatch", "\(totals)")
            // The fetch stopped at the list that went over. That list is not kept,
            // so what is kept fits in what the record said.
            XCTAssertLessThanOrEqual(dest.bytes(.fileList) + dest.bytes(.folderList), totals.listBytes, "\(totals)")
            XCTAssertLessThanOrEqual(UInt64(dest.count(.chunk)), totals.chunks)
            XCTAssertLessThanOrEqual(dest.bytes(.chunk), totals.chunkBytes)
        }
    }
}
