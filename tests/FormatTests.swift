import XCTest
@testable import ScionicMerkleTree

final class FormatTests: XCTestCase {
    private func chunk(_ seed: UInt8, _ length: UInt32) -> ChunkRef {
        ChunkRef(hash: Hash.of([seed]), length: length)
    }

    private func file(_ seed: UInt8) -> Target {
        try! FileList(items: [chunk(seed, UInt32(seed) + 1)]).target
    }

    private func entry(_ name: String, _ target: Target) -> Entry {
        try! Entry(name: name, target: target)
    }

    private func folder(_ names: [String]) -> FolderList {
        try! FolderList(entries: names.enumerated().map { entry($0.element, file(UInt8($0.offset))) })
    }

    private func sha(_ parts: [UInt8]...) -> Hash {
        Hash.of(parts.flatMap { $0 })
    }

    /// An entry's bytes, written by hand.
    private func entryBytes(_ kind: UInt8, _ size: UInt64, _ hash: Hash, _ name: [UInt8], _ extra: [UInt8]) -> [UInt8] {
        [kind] + u64be(size) + hash.bytes + u16be(UInt16(name.count)) + name + extra
    }

    private let noExtra: [UInt8] = [0, 0]

    private func assertSizeOverflow(_ body: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ScionicError.sizeOverflow = error else {
                return XCTFail("\(error)", file: file, line: line)
            }
        }
    }

    func testEveryHashCoversExactlyTheBytesTheFormatNames() throws {
        // A file's list item, and its leaf.
        let first = chunk(1, 5)
        let second = chunk(2, 7)
        let item = first.hash.bytes + u32be(5)
        let one = try FileList(items: [first])
        XCTAssertEqual(one.encode(), item)
        let firstLeaf = sha([0x00], item)
        XCTAssertEqual(first.leaf, Node(hash: firstLeaf, size: 5))

        // A file of one chunk: the leaf is the top of its list.
        XCTAssertEqual(one.hash, sha([0x10], u64be(1), u64be(5), firstLeaf.bytes))

        // A file of two chunks: the top is a fork over the two leaves.
        let secondLeaf = second.leaf.hash
        let top = sha([0x01], firstLeaf.bytes, u64be(5), u64be(1), secondLeaf.bytes, u64be(7), u64be(1))
        let two = try FileList(items: [first, second])
        XCTAssertEqual(two.size, 12)
        XCTAssertEqual(two.hash, sha([0x10], u64be(2), u64be(12), top.bytes))

        // An entry with extra data, and its leaf.
        let extra = try ExtraData().with("mode", text: "644").with("a", [0xFF])
        let named = try Entry(name: "b.txt", target: two.target, extra: extra)
        let extraBytes: [UInt8] = [0, 2] + [0, 1] + bytes("a") + [0, 1, 0xFF] + [0, 4] + bytes("mode") + [0, 3] + bytes("644")
        let namedBytes = entryBytes(1, 12, two.hash, bytes("b.txt"), extraBytes)
        var encoded: [UInt8] = []
        named.encode(into: &encoded)
        XCTAssertEqual(encoded, namedBytes)
        XCTAssertEqual(named.encodedCount, namedBytes.count)
        let namedLeaf = sha([0x02], namedBytes)
        XCTAssertEqual(named.leaf, Node(hash: namedLeaf, size: 12))

        // A folder of an empty folder and that file.
        let empty = try FolderList(entries: [])
        XCTAssertEqual(empty.hash, sha([0x11], u64be(0), u64be(0), [UInt8](repeating: 0, count: 32)))
        let inner = entry("a", empty.target)
        let innerBytes = entryBytes(2, 0, empty.hash, bytes("a"), noExtra)
        let innerLeaf = sha([0x02], innerBytes)
        let both = try FolderList(entries: [inner, named])
        XCTAssertEqual(both.encode(), innerBytes + namedBytes)
        XCTAssertEqual(both.encodedCount, UInt64(innerBytes.count + namedBytes.count))
        let folderTop = sha([0x03], innerLeaf.bytes, u64be(0), u64be(1), namedLeaf.bytes, u64be(12), u64be(1), bytes("b.txt"))
        XCTAssertEqual(both.hash, sha([0x11], u64be(2), u64be(12), folderTop.bytes))

        // The record, and the root.
        let totals = Totals(chunks: 2, chunkBytes: 12, listBytes: 72 + both.encodedCount)
        let record = try Record(top: both.target, totals: totals, chunking: Chunking.fixed(5))
        var recordBytes: [UInt8] = [0x20, 2] + u64be(12) + both.hash.bytes + u64be(2) + u64be(12) + u64be(totals.listBytes)
        recordBytes += [0, 1, 0, 8] + bytes("chunking") + [0, 7] + bytes("fixed-5")
        XCTAssertEqual(record.encode(), recordBytes)
        XCTAssertEqual(record.root.hash, Hash.of(recordBytes))
        XCTAssertEqual(try Record(decoding: recordBytes), record)
    }

    func testTheSameThingHasTheSameHashWhereverItIs() throws {
        // A file's hash covers its chunks, and nothing about where it sits.
        let list = try FileList(items: [chunk(1, 5), chunk(2, 7), chunk(1, 5)])
        let here = try FolderList(entries: [entry("a.bin", list.target)])
        let there = try FolderList(entries: [entry("other", file(9)), entry("renamed.bin", list.target)])
        XCTAssertEqual(here.entries[0].hash, there.entries[1].hash)
        XCTAssertNotEqual(here.hash, there.hash)

        // A folder's hash covers its entries, and no name for itself.
        let outer = try FolderList(entries: [entry("one", here.target), entry("two", here.target)])
        XCTAssertEqual(outer.entries[0].hash, outer.entries[1].hash)
        XCTAssertEqual(outer.size, 2 * here.size)

        // Every empty file is one file, and it is not the empty folder.
        let emptyFile = try FileList(items: [])
        XCTAssertEqual(emptyFile.hash, fileHash(count: 0, size: 0, list: .zero))
        XCTAssertEqual(emptyFile, try FileList(decoding: []))
        let emptyFolder = try FolderList(decoding: [])
        XCTAssertEqual(emptyFolder.hash, folderHash(count: 0, size: 0, list: .zero))
        XCTAssertNotEqual(emptyFile.hash, emptyFolder.hash)

        // The chunks' order, their number and their lengths are all covered.
        let otherOrder = try FileList(items: [chunk(2, 7), chunk(1, 5), chunk(1, 5)])
        let oneLess = try FileList(items: [chunk(1, 5), chunk(2, 7)])
        let otherLength = try FileList(items: [chunk(1, 5), chunk(2, 6), chunk(1, 6)])
        XCTAssertEqual(otherLength.size, list.size)
        for other in [otherOrder, oneLess, otherLength] {
            XCTAssertNotEqual(other.hash, list.hash)
        }
    }

    func testAnEntryDiffersWithItsNameKindSizeHashAndExtraData() throws {
        let target = file(1)
        let base = try FolderList(entries: [entry("a", target)])
        var asFolder = target
        asFolder.kind = .folder
        var resized = target
        resized.size += 1
        let others = [
            try FolderList(entries: [entry("b", target)]),
            try FolderList(entries: [entry("a", asFolder)]),
            try FolderList(entries: [entry("a", resized)]),
            try FolderList(entries: [entry("a", file(2))]),
            try FolderList(entries: [Entry(name: "a", target: target, extra: ExtraData().with("mode", text: "755"))]),
        ]
        for other in others {
            XCTAssertNotEqual(other.hash, base.hash)
        }
    }

    func testNamesAreHeldToTheRules() throws {
        for name in ["a", "A", ".a", "...", "a b", "a\\b", "\u{E9}t\u{E9}", String(repeating: "x", count: 255)] {
            XCTAssertNoThrow(try checkName(name), name)
        }
        for name in ["", ".", "..", "a/b", "/", "a\u{0}b", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try checkName(name), name)
            XCTAssertThrowsError(try Entry(name: name, target: file(1)), name)
        }
        // Names are compared as bytes: these are two names.
        XCTAssertNoThrow(try FolderList(entries: [entry("File", file(1)), entry("file", file(2))]))
        // And these two, which Swift takes for one string, are two names too.
        let decomposed = entry("e\u{301}", file(1))
        let composed = entry("\u{E9}", file(2))
        let list = try FolderList(entries: [decomposed, composed])
        XCTAssertEqual(list.get("\u{E9}")?.hash, file(2).hash)
        XCTAssertEqual(list.get("e\u{301}")?.hash, file(1).hash)
        XCTAssertThrowsError(try FolderList(entries: [composed, decomposed]))
        // A name that is not UTF-8 is no name.
        XCTAssertThrowsError(try Entry(nameBytes: [0xFF, 0xFE], target: file(1)))
    }

    func testAFolderListIsSortedByItsNamesBytesWithNoNameTwice() throws {
        XCTAssertThrowsError(try FolderList(entries: [entry("b", file(1)), entry("a", file(2))]))
        XCTAssertThrowsError(try FolderList(entries: [entry("a", file(1)), entry("a", file(1))]))
        // Bytes, not letters: "Z" sorts before "a", and "a" before "a0".
        let list = folder(["Z", "a", "a0", "b"])
        XCTAssertEqual(list.get("a0")?.name, "a0")
        XCTAssertNil(list.get("a1"))
        XCTAssertThrowsError(try FolderList(decoding: list.encode() + folder(["B"]).encode()))
        XCTAssertThrowsError(try FolderList(decoding: folder(["a"]).encode() + folder(["a"]).encode()))
    }

    func testExtraDataIsHeldToItsLimitsAndReadInOneWayOnly() throws {
        var extra = ExtraData()
        XCTAssertThrowsError(try extra.insert("", text: "x"))
        XCTAssertThrowsError(try extra.insert(String(repeating: "n", count: 65), text: "x"))
        XCTAssertNoThrow(try extra.insert(String(repeating: "n", count: 64), [UInt8](repeating: 0, count: 1024)))
        XCTAssertThrowsError(try extra.insert("big", [UInt8](repeating: 0, count: 1025)))
        for index in 0..<31 {
            try extra.insert("k" + padded(index, 2), text: "v")
        }
        XCTAssertEqual(extra.count, 32)
        XCTAssertThrowsError(try extra.insert("one-more", text: "v"))
        XCTAssertNoThrow(try extra.insert("k00", text: "again"), "a name that is there is set again")
        XCTAssertEqual(extra.text("k00"), "again")

        func read(_ input: [UInt8]) throws -> ExtraData {
            var reader = ByteReader(input, what: "extra data")
            let extra = try ExtraData.decode(&reader)
            try reader.finish()
            return extra
        }
        var written: [UInt8] = []
        extra.encode(into: &written)
        XCTAssertEqual(written.count, extra.encodedCount)
        XCTAssertEqual(try read(written), extra)

        XCTAssertTrue(try read([0, 0]).isEmpty)
        let good: [UInt8] = [0, 2, 0, 1, UInt8(ascii: "a"), 0, 1, 1, 0, 1, UInt8(ascii: "b"), 0, 0]
        XCTAssertEqual(try read(good).count, 2)
        let a = UInt8(ascii: "a")
        let b = UInt8(ascii: "b")
        let bad: [[UInt8]] = [
            [0, 2, 0, 1, b, 0, 0, 0, 1, a, 0, 0], // out of order
            [0, 2, 0, 1, a, 0, 0, 0, 1, a, 0, 0], // a name twice
            [0, 1, 0, 0, 0, 0], // an empty name
            [0, 1, 0, 1, 0xFF, 0, 0], // a name that is not UTF-8
            [0, 1, 0, 1, a, 0, 5, 1], // cut short
            [0, 2, 0, 1, a, 0, 0], // a count that is too high
            [0, 0, 0], // bytes after the end
            [0, 33],
            [],
        ]
        for input in bad {
            XCTAssertThrowsError(try read(input), "\(input)")
        }
        XCTAssertThrowsError(try read([0, 1, 0, 65] + [UInt8](repeating: UInt8(ascii: "n"), count: 65) + [0, 0]))
        XCTAssertThrowsError(try read([0, 1, 0, 1, a, 0x04, 0x01] + [UInt8](repeating: 0, count: 1025)))
    }

    func testListsAreReadStrictly() throws {
        let hash = Hash.of(bytes("x"))
        // A file's list: whole items, and chunks of 1 byte to 8 MiB.
        func item(_ length: UInt32) -> [UInt8] {
            hash.bytes + u32be(length)
        }
        XCTAssertNoThrow(try FileList(decoding: item(1)))
        XCTAssertNoThrow(try FileList(decoding: item(UInt32(Scionic.maxChunkBytes))))
        XCTAssertThrowsError(try FileList(decoding: item(0)))
        XCTAssertThrowsError(try FileList(decoding: item(UInt32(Scionic.maxChunkBytes) + 1)))
        XCTAssertThrowsError(try FileList(decoding: Array(item(1)[..<35])))
        XCTAssertThrowsError(try FileList(decoding: item(1) + [0]))
        XCTAssertThrowsError(try ChunkRef.of([UInt8]()))
        XCTAssertEqual(try ChunkRef.of(bytes("x")), ChunkRef(hash: hash, length: 1))

        // A folder's list: every entry whole, of a known kind, validly named.
        XCTAssertNoThrow(try FolderList(decoding: entryBytes(1, 3, hash, bytes("a"), noExtra)))
        XCTAssertNoThrow(try FolderList(decoding: entryBytes(2, 3, hash, bytes("a"), noExtra)))
        for kind: UInt8 in [0, 3, 0xFF] {
            XCTAssertThrowsError(try FolderList(decoding: entryBytes(kind, 3, hash, bytes("a"), noExtra)))
        }
        let names: [[UInt8]] = [[], bytes("."), bytes(".."), bytes("a/b"), [UInt8(ascii: "a"), 0], [0xFF, 0xFE], [UInt8](repeating: UInt8(ascii: "x"), count: 256)]
        for name in names {
            XCTAssertThrowsError(try FolderList(decoding: entryBytes(1, 3, hash, name, noExtra)), "\(name)")
        }
        let whole = entryBytes(1, 3, hash, bytes("a"), noExtra)
        for cut in 1..<whole.count {
            XCTAssertThrowsError(try FolderList(decoding: Array(whole[..<cut])), "cut at \(cut)")
        }
        XCTAssertThrowsError(try FolderList(decoding: whole + [0]))
        // A list's sizes are added up, and a sum that does not fit is refused.
        let huge = entryBytes(1, UInt64.max, hash, bytes("a"), noExtra) + entryBytes(1, 1, hash, bytes("b"), noExtra)
        assertSizeOverflow(try FolderList(decoding: huge))
    }

    func testARecordIsReadStrictly() throws {
        let top = folder(["a", "b"]).target
        let totals = Totals(chunks: 2, chunkBytes: 3, listBytes: 200)
        let extra = try ExtraData()
            .with(Scionic.chunkingKey, text: "a caller cannot set this")
            .with(Scionic.timestampKey, text: "2026-11-12T00:00:00Z")
        let record = try Record(top: top, totals: totals, chunking: .fastCDCv1, extra: extra)
        XCTAssertEqual(record.extra.text(Scionic.chunkingKey), "fastcdc-v1")
        XCTAssertEqual(record.chunking, .fastCDCv1)
        XCTAssertEqual(record.top, top)
        XCTAssertEqual(record.totals, totals)
        let encoded = record.encode()
        XCTAssertEqual(try Record(decoding: encoded), record)
        XCTAssertEqual(record.root, Root.of(record: encoded))

        for cut in 0..<encoded.count {
            XCTAssertThrowsError(try Record(decoding: Array(encoded[..<cut])), "cut at \(cut)")
        }
        XCTAssertThrowsError(try Record(decoding: encoded + [0]))
        var otherMark = encoded
        otherMark[0] = 0x21
        XCTAssertThrowsError(try Record(decoding: otherMark))
        var otherKind = encoded
        otherKind[1] = 3
        XCTAssertThrowsError(try Record(decoding: otherKind))

        // A record that does not say how its tree was chunked is no record.
        XCTAssertThrowsError(try Record(decoding: Array(encoded[..<66]) + noExtra))
        let unknown = Array(encoded[..<66]) + [0, 1, 0, 8] + bytes("chunking") + [0, 8] + bytes("fixed-2m")
        XCTAssertThrowsError(try Record(decoding: unknown))

        // Totals that no tree can have.
        let badTotals: [(UInt64, UInt64, UInt64)] = [
            (3, 2, 200), // more chunks than chunk bytes
            (1, top.size + 1, 200), // more chunk bytes than the tree holds
            (2, 3, 71), // lists too short to name the chunks
            (0, 1, 0), // bytes without chunks
        ]
        for (chunks, chunkBytes, listBytes) in badTotals {
            let totals = Totals(chunks: chunks, chunkBytes: chunkBytes, listBytes: listBytes)
            XCTAssertThrowsError(try Record(top: top, totals: totals, chunking: .fastCDCv1), "\(totals)")
        }
        let fileTop = try FileList(items: [chunk(1, 5)]).target
        let uneven = Totals(chunks: 1, chunkBytes: 5, listBytes: 37)
        XCTAssertThrowsError(try Record(top: fileTop, totals: uneven, chunking: .fastCDCv1))
    }

    func testAWayOfChunkingHasOneSpellingAndHoldsChunksToItsLengths() throws {
        XCTAssertEqual(Chunking.fastCDCv1.tag, "fastcdc-v1")
        XCTAssertEqual(try Chunking.fixed(16).tag, "fixed-16")
        for chunking in [Chunking.fastCDCv1, try .fixed(1), try .fixed(16), try .fixed(UInt32(Scionic.maxChunkBytes))] {
            XCTAssertEqual(try Chunking(tag: bytes(chunking.tag)), chunking)
        }
        for tag in [
            "", "fastcdc-v2", "FASTCDC-V1", "fastcdc-v1 ", "fixed-", "fixed-0", "fixed-016", "fixed-+16",
            "fixed-16 ", "fixed-2m", "fixed-8388609", "fixed-99999999", "fixed-4294967297",
        ] {
            XCTAssertThrowsError(try Chunking(tag: bytes(tag)), tag)
        }

        let content = Chunking.fastCDCv1
        let min = UInt32(FastCDC.minSize)
        let max = UInt32(FastCDC.maxSize)
        XCTAssertNoThrow(try content.checkLength(min + 1, isLast: false))
        XCTAssertNoThrow(try content.checkLength(max, isLast: false))
        XCTAssertThrowsError(try content.checkLength(min, isLast: false), "the chunker never stops there")
        XCTAssertThrowsError(try content.checkLength(1, isLast: false))
        XCTAssertNoThrow(try content.checkLength(1, isLast: true))
        XCTAssertNoThrow(try content.checkLength(max, isLast: true))
        XCTAssertThrowsError(try content.checkLength(max + 1, isLast: true))
        XCTAssertThrowsError(try content.checkLength(0, isLast: true))

        let fixed = try Chunking.fixed(16)
        XCTAssertNoThrow(try fixed.checkLength(16, isLast: false))
        XCTAssertThrowsError(try fixed.checkLength(15, isLast: false))
        XCTAssertThrowsError(try fixed.checkLength(17, isLast: false))
        XCTAssertNoThrow(try fixed.checkLength(1, isLast: true))
        XCTAssertNoThrow(try fixed.checkLength(16, isLast: true))
        XCTAssertThrowsError(try fixed.checkLength(17, isLast: true))
        XCTAssertThrowsError(try fixed.checkLength(0, isLast: true))
    }

    func testAFilesSizeBoundsHowManyChunksItCanHave() throws {
        let step = UInt64(FastCDC.minSize) + 1
        let max = UInt64(FastCDC.maxSize)
        let content = Chunking.fastCDCv1
        func bounds(_ chunking: Chunking, _ size: UInt64) -> [UInt64] {
            let (fewest, most) = chunking.countBounds(size: size)
            return [fewest, most]
        }
        XCTAssertEqual(bounds(content, 0), [0, 0])
        XCTAssertEqual(bounds(content, 1), [1, 1])
        XCTAssertEqual(bounds(content, step), [1, 1])
        XCTAssertEqual(bounds(content, step + 1), [1, 2])
        XCTAssertEqual(bounds(content, max), [1, 16])
        XCTAssertEqual(bounds(content, max + 1), [2, 16])
        XCTAssertEqual(bounds(content, 2 * step + 1), [1, 3])
        // A terabyte: at most about two million chunks, never a billion. The
        // most is 2,097,148 chunks of 524,289 bytes, and a last one of 4.
        let (fewest, most) = content.countBounds(size: 1 << 40)
        XCTAssertEqual(fewest, 131_072)
        XCTAssertEqual(most, 2_097_149)
        XCTAssertEqual(2_097_148 * step + 4, 1 << 40)
        XCTAssertNoThrow(try content.checkCount(size: 1 << 40, count: 500_000))
        XCTAssertThrowsError(try content.checkCount(size: 1 << 40, count: most + 1))
        XCTAssertThrowsError(try content.checkCount(size: 1 << 40, count: fewest - 1))
        XCTAssertThrowsError(try content.checkCount(size: 0, count: 1))

        // What the bounds say is what lists of fitting chunks can add up to.
        let fixed = try Chunking.fixed(4)
        for size in 0..<UInt64(40) {
            let chunks = UInt64(fixed.cut([UInt8](repeating: 0, count: Int(size))).count)
            XCTAssertEqual(bounds(fixed, size), [chunks, chunks], "size \(size)")
        }
        let list = try FileList(items: [chunk(1, 4), chunk(2, 4), chunk(3, 3)])
        XCTAssertNoThrow(try list.checkChunking(fixed))
        XCTAssertThrowsError(try list.checkChunking(Chunking.fixed(5)))
        XCTAssertThrowsError(try list.checkChunking(content))
        let shortInTheMiddle = try FileList(items: [chunk(1, 4), chunk(2, 3), chunk(3, 4)])
        XCTAssertThrowsError(try shortInTheMiddle.checkChunking(fixed))
        XCTAssertNoThrow(try FileList(items: []).checkChunking(content))
    }

    func testEveryBranchOfAFileChecksAndGivesTheByteItStartsAt() throws {
        for count in UInt8(1)...17 {
            let items = (0..<count).map { chunk($0, UInt32($0 % 5) + 1) }
            let list = try FileList(items: items)
            let open = try OpenFile(list)
            let target = list.target
            for start in 0..<UInt64(count) {
                for end in (start + 1)...UInt64(count) {
                    let branch = try open.open(start: start, end: end)
                    XCTAssertEqual(branch, try list.open(start: start, end: end))
                    XCTAssertEqual(try FileBranch(decoding: branch.encode()), branch)
                    let before = items[..<Int(start)].reduce(UInt64(0)) { $0 + UInt64($1.length) }
                    XCTAssertEqual(try branch.check(file: target, chunking: nil), before)
                    XCTAssertEqual(open.startOf(start), before)
                    XCTAssertEqual(branch.items, Array(items[Int(start)..<Int(end)]))
                }
            }
            XCTAssertEqual(open.startOf(UInt64(count)), list.size)
            XCTAssertNil(open.startOf(UInt64(count) + 1))
        }
    }

    func testABranchOfAFileIsRefusedForAnyOtherFileCountOrPlace() throws {
        let items = (UInt8(0)..<9).map { chunk($0, 4) }
        let list = try FileList(items: items)
        let target = list.target
        let branch = try list.open(start: 3, end: 5)
        XCTAssertEqual(try branch.check(file: target, chunking: nil), 12)

        // Another file, another size, and a folder.
        XCTAssertThrowsError(try branch.check(file: file(1), chunking: nil)) { error in
            guard case ScionicError.sizeMismatch = error else { return XCTFail("\(error)") }
        }
        var otherHash = target
        otherHash.hash = Hash.of(bytes("other"))
        XCTAssertThrowsError(try branch.check(file: otherHash, chunking: nil)) { error in
            guard case ScionicError.hashMismatch = error else { return XCTFail("\(error)") }
        }
        var otherSize = target
        otherSize.size += 1
        XCTAssertThrowsError(try branch.check(file: otherSize, chunking: nil)) { error in
            guard case ScionicError.sizeMismatch = error else { return XCTFail("\(error)") }
        }
        var asFolder = target
        asFolder.kind = .folder
        XCTAssertThrowsError(try branch.check(file: asFolder, chunking: nil))

        // The same bytes with another count, another place, or one item less.
        let encoded = branch.encode()
        func with(_ at: Int, _ value: UInt8) throws {
            var changed = encoded
            changed[at] = value
            try FileBranch(decoding: changed).check(file: target, chunking: nil)
        }
        XCTAssertThrowsError(try with(7, 10), "as a file of 10 chunks")
        XCTAssertThrowsError(try with(7, 8), "as a file of 8 chunks")
        XCTAssertThrowsError(try with(15, 4), "one place on")
        XCTAssertThrowsError(try with(15, 2), "one place back")
        XCTAssertThrowsError(try with(19, 1), "one item less")
        XCTAssertThrowsError(try with(19, 0), "no items")
        XCTAssertThrowsError(try with(20, 0), "another chunk")
        let last = encoded.count - 1
        XCTAssertThrowsError(try with(last, encoded[last] ^ 1), "another size for a carried node")
        for cut in 0..<encoded.count {
            XCTAssertThrowsError(try FileBranch(decoding: Array(encoded[..<cut])), "cut at \(cut)")
        }
        XCTAssertThrowsError(try FileBranch(decoding: encoded + [0]))

        // The chunks' lengths are held to the way of chunking, when one is given.
        XCTAssertNoThrow(try branch.check(file: target, chunking: Chunking.fixed(4)))
        XCTAssertThrowsError(try branch.check(file: target, chunking: Chunking.fixed(5)))
        XCTAssertThrowsError(try branch.check(file: target, chunking: .fastCDCv1))

        // A branch that claims more carried nodes than any list needs.
        let crowded = Array(encoded[..<(20 + 2 * Scionic.listItemBytes)]) + u16be(81) + [UInt8](repeating: 0, count: 81 * 40)
        XCTAssertThrowsError(try FileBranch(decoding: crowded))
        // A branch that claims more items than it has bytes for.
        XCTAssertThrowsError(try FileBranch(decoding: Array(encoded[..<16]) + u32be(UInt32.max)))
    }

    func testTheChunksThatHoldAStretchOfBytesAreFound() throws {
        let lengths: [UInt32] = [3, 1, 4, 1, 5, 9, 2, 6]
        let list = try FileList(items: lengths.enumerated().map { chunk(UInt8($0.offset), $0.element) })
        let open = try OpenFile(list)
        let size = list.size
        XCTAssertEqual(size, 31)
        // Which chunk holds each byte, worked out the long way.
        var holder: [UInt64] = []
        for (index, length) in lengths.enumerated() {
            holder += [UInt64](repeating: UInt64(index), count: Int(length))
        }
        for offset in 0..<size {
            for length in 1...(size - offset) {
                let (first, after) = try open.chunksFor(offset: offset, length: length)
                XCTAssertEqual(first, holder[Int(offset)], "\(offset)+\(length)")
                XCTAssertEqual(after, holder[Int(offset + length - 1)] + 1, "\(offset)+\(length)")
                let branch = try open.openBytes(offset: offset, length: length)
                let startsAt = try branch.check(file: list.target, chunking: nil)
                XCTAssertLessThanOrEqual(startsAt, offset)
                let shown = branch.items.reduce(UInt64(0)) { $0 + UInt64($1.length) }
                XCTAssertGreaterThanOrEqual(startsAt + shown, offset + length)
            }
        }
        XCTAssertThrowsError(try open.chunksFor(offset: 0, length: 0))
        XCTAssertThrowsError(try open.chunksFor(offset: size, length: 1))
        XCTAssertThrowsError(try open.chunksFor(offset: size - 1, length: 2))
        XCTAssertThrowsError(try open.chunksFor(offset: UInt64.max, length: 2))
        XCTAssertThrowsError(try OpenFile(FileList(items: [])).chunksFor(offset: 0, length: 1))
    }

    func testEveryBranchOfAFolderChecksAndReadsBack() throws {
        let names = (0..<13).map { "n" + padded($0, 2) }
        for count in 1...names.count {
            let list = folder(Array(names[..<count]))
            let open = try OpenFolder(list)
            let target = list.target
            var asFile = target
            asFile.kind = .file
            for start in 0..<UInt64(count) {
                for end in (start + 1)...UInt64(count) {
                    let branch = try open.open(start: start, end: end)
                    XCTAssertEqual(branch, try list.open(start: start, end: end))
                    XCTAssertEqual(try FolderBranch(decoding: branch.encode()), branch)
                    XCTAssertNoThrow(try branch.check(folder: target))
                    XCTAssertEqual(branch.entries, Array(list.entries[Int(start)..<Int(end)]))
                    XCTAssertThrowsError(try branch.check(folder: folder(["other"]).target))
                    XCTAssertThrowsError(try branch.check(folder: asFile))
                }
            }
        }
    }

    func testANameIsShownToBeThereOrNotThereByItsOnePlace() throws {
        let names = ["b", "d", "f", "h", "j", "l", "n"]
        let asked = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "b0", "B"]
        for count in 1...names.count {
            let list = folder(Array(names[..<count]))
            let target = list.target
            for name in asked {
                let place = try XCTUnwrap(list.placeOf(name))
                let truth = list.get(name)
                // The answer the folder gives.
                let answer = try list.openName(name)
                XCTAssertEqual(try FolderBranch(decoding: answer.encode()), answer)
                XCTAssertEqual(try answer.check(folder: target, name: name), truth)
                // Any other entry shown in its place is refused, so there is one
                // answer, and it is the true one.
                for other in 0..<UInt64(count) {
                    let shown = try list.open(start: other, end: other + 1)
                    if other == place {
                        XCTAssertEqual(try shown.check(folder: target, name: name), truth, "\(count): \(name) at \(other)")
                    } else {
                        XCTAssertThrowsError(try shown.check(folder: target, name: name), "\(count): \(name) at \(other)")
                    }
                }
                // A branch of two entries is no answer for one name.
                if count >= 2 {
                    XCTAssertThrowsError(try list.open(start: 0, end: 2).check(folder: target, name: name))
                }
            }
            XCTAssertThrowsError(try list.openName("a/b"))
            XCTAssertThrowsError(try list.open(start: 0, end: 1).check(folder: target, name: ""))
        }
    }

    func testAnEmptyFolderShowsThatItHoldsNoName() throws {
        let empty = try FolderList(entries: [])
        XCTAssertNil(empty.placeOf("a"))
        let answer = try empty.openName("a")
        XCTAssertEqual(try FolderBranch(decoding: answer.encode()), answer)
        XCTAssertNil(try answer.check(folder: empty.target, name: "a"))
        XCTAssertNoThrow(try answer.check(folder: empty.target))
        // The same answer for a folder that is not empty is refused.
        let full = folder(["a"])
        XCTAssertThrowsError(try answer.check(folder: full.target, name: "a"))
        XCTAssertThrowsError(try answer.check(folder: full.target))
        // And a branch that shows nothing of a folder with entries is no branch.
        XCTAssertThrowsError(try FolderBranch(decoding: u64be(3) + [UInt8](repeating: 0, count: 8 + 4 + 2)))
        let carrying = u64be(0) + [UInt8](repeating: 0, count: 8 + 4) + [0, 1] + [UInt8](repeating: 0, count: 40) + [0, 1, UInt8(ascii: "a")]
        XCTAssertThrowsError(try FolderBranch(decoding: carrying))
    }
}
