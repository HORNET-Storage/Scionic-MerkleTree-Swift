import XCTest
@testable import ScionicMerkleTree

final class FastCDCTests: XCTestCase {
    private func lengths(_ chunking: Chunking, _ data: [UInt8]) -> [Int] {
        data.withUnsafeBytes { chunking.cutLengths($0) }
    }

    /// The lengths of the chunks of `data`, found with `threads` threads.
    private func onThreads(_ data: ArraySlice<UInt8>, ended: Bool, _ threads: Int) -> [Int] {
        data.withUnsafeBytes { fastCDCLengths($0, ended: ended, threads: threads) }
    }

    /// The lengths of the chunks of `data`, each cut by the plain boundary.
    private func plainLengths(_ data: [UInt8]) -> [Int] {
        data.withUnsafeBytes { raw in
            var lengths: [Int] = []
            var offset = 0
            while offset < raw.count {
                let length = fastCDCBoundaryPlain(UnsafeRawBufferPointer(rebasing: raw[offset...]))
                lengths.append(length)
                offset += length
            }
            return lengths
        }
    }

    func testGearTableMatchesSeedDerivation() {
        for index in 0..<256 {
            let digest = Hash.of(bytes(FastCDC.gearSeedPrefix) + [UInt8(index)]).bytes
            let expected = digest[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            XCTAssertEqual(fastCDCGear[index], expected, "G[\(index)] drifted from the fastcdc-v1 seed derivation")
        }
        XCTAssertEqual(fastCDCGear.count, 256)
    }

    func testGearTableEyeballAnchorsMatchTheSpec() {
        XCTAssertEqual(fastCDCGear[0], 0x947E_4E1B_8BED_AB5D)
        XCTAssertEqual(fastCDCGear[1], 0xD7D7_F340_329C_706E)
    }

    func testConstantsAreFrozen() {
        XCTAssertEqual(FastCDC.minSize, 512 * 1024)
        XCTAssertEqual(FastCDC.targetSize, 2048 * 1024)
        XCTAssertEqual(FastCDC.maxSize, 8192 * 1024)
        XCTAssertEqual(FastCDC.strictMask, ~UInt64(0) << 41, "the strict mask is the top 23 bits")
        XCTAssertEqual(FastCDC.looseMask, ~UInt64(0) << 45, "the loose mask is the top 19 bits")
        XCTAssertEqual(FastCDC.strictMask.nonzeroBitCount, 23)
        XCTAssertEqual(FastCDC.looseMask.nonzeroBitCount, 19)
        XCTAssertEqual(FastCDC.strictMask & FastCDC.looseMask, FastCDC.looseMask, "the loose mask is part of the strict one")
    }

    func testCutBoundsAndDeterminism() {
        let data = corpusBytes("scionic-fastcdc-v1:test:bounds", 40 << 20)
        let first = lengths(.fastCDCv1, data)
        XCTAssertEqual(first, lengths(.fastCDCv1, data), "two cuts of the same bytes agree")
        XCTAssertFalse(first.isEmpty)
        for (index, length) in first.enumerated() {
            if index < first.count - 1 {
                XCTAssertGreaterThan(length, FastCDC.minSize, "chunk \(index) is \(length) bytes")
            }
            XCTAssertLessThanOrEqual(length, FastCDC.maxSize, "chunk \(index) is too long")
        }
        let total = first.reduce(0, +)
        XCTAssertEqual(total, data.count, "the chunks cover the input exactly")
        let mean = total / first.count
        XCTAssertTrue((1 << 20)...(4 << 20) ~= mean, "mean chunk size \(mean) is outside 1 to 4 MiB")
    }

    func testStreamingMatchesCuttingInMemory() throws {
        let sizes = [
            0, 100, FastCDC.minSize, FastCDC.minSize + 1, FastCDC.targetSize,
            FastCDC.maxSize, FastCDC.maxSize + 1, 3 << 20, 20 << 20,
        ]
        let corpus = corpusBytes("scionic-fastcdc-v1:test:stream", 20 << 20)
        let chunker = StreamChunker()
        for chunking in [Chunking.fastCDCv1, try Chunking.fixed(1 << 20)] {
            for size in sizes {
                let data = Array(corpus[..<size])
                let expected = chunking.cut(data).map { Array($0) }
                // The smallest window, one that is filled several times, and one
                // that the whole stream fits into.
                for room in [0, 2 * FastCDC.maxSize, 5 * FastCDC.maxSize + 3] {
                    var streamed: [[UInt8]] = []
                    var offset = 0
                    let step = 64 * 1024 + 17
                    try chunker.cut(chunking, room: room, read: { buffer in
                        let take = min(step, buffer.count, data.count - offset)
                        if take > 0 {
                            data.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + take)])) }
                        }
                        offset += take
                        return take
                    }, onChunks: { chunks in
                        streamed.append(contentsOf: chunks.map { Array($0) })
                    })
                    XCTAssertEqual(streamed, expected, "\(chunking), \(size) bytes, room \(room)")
                }
            }
        }
    }

    func testTheFastBoundaryIsThePlainOne() {
        let corpus = corpusBytes("scionic-fastcdc-v1:test:boundary", 24 << 20)
        var strict = 0
        var loose = 0
        var steps = Set<Int>()
        func check(_ data: ArraySlice<UInt8>) {
            data.withUnsafeBytes { raw in
                let cut = fastCDCBoundary(raw)
                XCTAssertEqual(cut, fastCDCBoundaryPlain(raw), "length \(raw.count)")
                if cut > FastCDC.minSize && cut < min(raw.count, FastCDC.maxSize) {
                    steps.insert((cut - FastCDC.minSize) % 4)
                    if cut <= FastCDC.targetSize {
                        strict += 1
                    } else {
                        loose += 1
                    }
                }
            }
        }
        // Whole windows, from many starts.
        for start in stride(from: 0, to: corpus.count - FastCDC.maxSize, by: 262_139) {
            check(corpus[start...])
        }
        // Windows that end at every kind of place: around the floor, around the
        // switch of masks, around the ceiling, and a few bytes on.
        for edge in [FastCDC.minSize, FastCDC.targetSize, FastCDC.maxSize] {
            for length in (edge - 5)...(edge + 9) {
                check(corpus[1_000_003..<(1_000_003 + length)])
            }
        }
        // Bytes that never match are cut at the ceiling, or where they end.
        let zeros = [UInt8](repeating: 0, count: FastCDC.maxSize + 7)
        check(zeros[...])
        check(zeros[..<(FastCDC.targetSize + 2)])
        XCTAssertEqual(steps.count, 4, "a cut at every place within a step of four")
        XCTAssertTrue(strict > 0 && loose > 0, "cuts under both masks")
    }

    func testChunksFoundOnThreadsAreTheChunksOfOneThread() {
        let corpus = corpusBytes("scionic-fastcdc-v1:test:threads", 12 << 20)
        let zeros = [UInt8](repeating: 0, count: 3 * FastCDC.maxSize + 5)
        let lengths = [
            0, 1, FastCDC.minSize, FastCDC.minSize + 1,
            firstWholeHash - 1, firstWholeHash, firstWholeHash + 1,
            FastCDC.targetSize + 3, FastCDC.maxSize, FastCDC.maxSize + 1, corpus.count,
        ]
        for data in lengths.map({ corpus[..<$0] }) + [zeros[...]] {
            for ended in [true, false] {
                let expected = onThreads(data, ended: ended, 1)
                if ended {
                    XCTAssertEqual(expected, data.withUnsafeBytes { Chunking.fastCDCv1.cutLengths($0) })
                }
                // Stretches of every length, and so ends at every place.
                for threads in [2, 3, 5, 8, 13] {
                    XCTAssertEqual(
                        onThreads(data, ended: ended, threads), expected,
                        "length \(data.count), \(threads) threads, ended \(ended)"
                    )
                }
            }
        }
        let matches = corpus.withUnsafeBytes { matchesOnThreads($0, 1) }
        XCTAssertTrue(matches.contains { $0.strict })
        XCTAssertTrue(matches.contains { !$0.strict })
        for threads in [2, 7, 24] {
            XCTAssertEqual(corpus.withUnsafeBytes { matchesOnThreads($0, threads) }, matches)
        }
    }

    func testAChunkIsJudgedByItsOwnHashWhereThatHoldsFewerThan64Bytes() {
        var data = corpusBytes("scionic-fastcdc-v1:test:short-hash", 6 << 20)
        // Three bytes whose hash matches the strict mask, as the first three that
        // a chunk hashes: they end the first chunk.
        data.replaceSubrange(FastCDC.minSize..<(FastCDC.minSize + 3), with: [158, 69, 185])
        let second = FastCDC.minSize + 3
        // 64 bytes whose own hash matches the strict mask, the last of them the
        // 11th that the second chunk hashes. The chunk's hash holds 11 bytes
        // there, and does not match: the chunk goes on.
        let window = (0..<61).map { UInt8(truncatingIfNeeded: 37 + 11 * $0) } + [6, 89, 219]
        let hash = window.reduce(UInt64(0)) { ($0 &<< 1) &+ fastCDCGear[Int($1)] }
        XCTAssertEqual(hash & FastCDC.strictMask, 0)
        let last = second + FastCDC.minSize + 10
        data.replaceSubrange((last + 1 - window.count)...last, with: window)

        let expected = plainLengths(data)
        XCTAssertEqual(expected[0], second)
        XCTAssertGreaterThan(expected[1], FastCDC.minSize + 11)
        let matches = data.withUnsafeBytes { matchesOnThreads($0, 2) }
        XCTAssertTrue(matches.contains(Match(at: last, strict: true)))
        for threads in [1, 2, 4] {
            XCTAssertEqual(onThreads(data[...], ended: true, threads), expected, "\(threads) threads")
        }
    }

    func testAChunkIsSettledOnceItsEndIsHeld() {
        let corpus = corpusBytes("scionic-fastcdc-v1:test:settled", 14 << 20)
        let whole = plainLengths(corpus)
        var ends = [0]
        for length in whole {
            ends.append(ends[ends.count - 1] + length)
        }
        XCTAssertGreaterThan(whole.count, 3, "several chunks")
        // Around where chunks end, and where the longest kind would end.
        var held: [Int] = []
        for end in ends[1..<4] {
            held += [end - 1, end, end + 1]
        }
        for start in ends[..<3] {
            held += [start + FastCDC.maxSize - 1, start + FastCDC.maxSize]
        }
        held += [FastCDC.minSize, firstWholeHash + 5]
        for count in held where count < corpus.count {
            for threads in [1, 3] {
                let settled = onThreads(corpus[..<count], ended: false, threads)
                // A chunk that is settled is one of the whole's: nothing that
                // comes later changes it.
                XCTAssertEqual(settled, Array(whole.prefix(settled.count)), "held \(count)")
                // And only the chunk that runs on past what is held is left.
                let reach = settled.reduce(0, +)
                let next = settled.count < whole.count ? whole[settled.count] : 0
                XCTAssertGreaterThanOrEqual(reach + next, count, "held \(count), \(threads) threads")
            }
        }
    }

    func testSmallInputsAreSingleChunks() {
        for length in [1, 100, FastCDC.minSize - 1, FastCDC.minSize] {
            let data = corpusBytes("scionic-fastcdc-v1:test:small", length)
            let chunks = Chunking.fastCDCv1.cut(data)
            XCTAssertEqual(chunks.count, 1, "\(length) bytes are one chunk")
            XCTAssertEqual(Array(chunks[0]), data)
        }
        XCTAssertTrue(Chunking.fastCDCv1.cut([]).isEmpty)
    }

    func testConstantBytesStayBounded() {
        // 20 MiB of zeros never matches either mask: every chunk is cut at the
        // most a chunk holds, with what is left as the last. The committed
        // vectors hold zeros_20mib as 8 MiB + 8 MiB + 4 MiB.
        XCTAssertEqual(lengths(.fastCDCv1, [UInt8](repeating: 0, count: 20 << 20)), [8 << 20, 8 << 20, 4 << 20])
        let letters = lengths(.fastCDCv1, [UInt8](repeating: UInt8(ascii: "a"), count: 20 << 20))
        for (index, length) in letters.enumerated() {
            XCTAssertLessThanOrEqual(length, FastCDC.maxSize)
            if index < letters.count - 1 {
                XCTAssertGreaterThan(length, FastCDC.minSize)
            }
        }
        XCTAssertEqual(letters.reduce(0, +), 20 << 20)
    }

    func testAnInsertReusesMostChunkContent() {
        let base = corpusBytes("scionic-fastcdc-v1:test:reuse", 32 << 20)
        let payload = corpusBytes("scionic-fastcdc-v1:test:reuse-payload", 4096)
        let edited = Array(base[..<(16 << 20)]) + payload + Array(base[(16 << 20)...])
        let known = Set(Chunking.fastCDCv1.cut(base).map { Hash.of($0) })
        let editedChunks = Chunking.fastCDCv1.cut(edited)
        let fresh = editedChunks.filter { !known.contains(Hash.of($0)) }.count
        XCTAssertGreaterThanOrEqual(fresh, 1, "an insert makes at least one new chunk")
        XCTAssertLessThanOrEqual(fresh, 3, "a 4 KiB insert made \(fresh) of \(editedChunks.count) chunks new")
    }

    func testEachWayOfChunkingCutsAsItSays() throws {
        let data = (0..<10).map { UInt8($0) }
        XCTAssertTrue(try Chunking.fixed(4).cut([]).isEmpty)
        XCTAssertEqual(try Chunking.fixed(4).cut(data).map { Array($0) }, [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
        XCTAssertEqual(try Chunking.fixed(5).cut(data).map { Array($0) }, [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9]])
        XCTAssertEqual(try Chunking.fixed(16).cut(data).map { Array($0) }, [data])
        XCTAssertEqual(Chunking.fastCDCv1.cut(data).map { Array($0) }, [data])
        XCTAssertThrowsError(try Chunking.fixed(0))
        XCTAssertNoThrow(try Chunking.fixed(UInt32(FastCDC.maxSize)))
        XCTAssertThrowsError(try Chunking.fixed(UInt32(FastCDC.maxSize) + 1))
    }
}
