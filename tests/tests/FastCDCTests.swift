import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Unit guards for the fastcdc-v1 port: frozen constants, the gear table's
/// seed derivation, boundary/cutter behavior, streaming ≡ slice equivalence,
/// and the tri-modal empty-file contract. The cross-language conformance
/// assertions live in FastCDCVectorTests.swift.
final class FastCDCTests: XCTestCase {

    /// The deterministic corpus generator shared with the conformance
    /// vectors: block k of the stream is SHA-256(seed ++ u64be(k)); blocks
    /// are concatenated and truncated to `length`.
    private func corpusBytes(_ seed: String, _ length: Int) -> Data {
        var out = Data(capacity: length + 32)
        var block: UInt64 = 0
        while out.count < length {
            var message = Data(seed.utf8)
            withUnsafeBytes(of: block.bigEndian) { message.append(contentsOf: $0) }
            out.append(sha256Digest(message))
            block += 1
        }
        out.removeSubrange(length..<out.count)
        return out
    }

    func testGearTableEyeballAnchorsMatchTheSpec() {
        XCTAssertEqual(fastCDCGear[0], 0x947e4e1b8bedab5d)
        XCTAssertEqual(fastCDCGear[1], 0xd7d7f340329c706e)
    }

    func testGearTableMatchesSeedDerivation() {
        for i in 0..<256 {
            var message = Data(fastCDCGearSeedPrefix.utf8)
            message.append(UInt8(i))
            let digest = sha256Digest(message)
            let expected = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            XCTAssertEqual(
                fastCDCGear[i], expected,
                "fastCDCGear[\(i)] drifted from the fastcdc-v1 seed derivation"
            )
        }
    }

    func testConstantsAreFrozen() {
        XCTAssertEqual(fastCDCMinSize, 512 * 1024)
        XCTAssertEqual(fastCDCTargetSize, 2048 * 1024)
        XCTAssertEqual(fastCDCMaxSize, 8192 * 1024)
        let allOnes = ~UInt64(0)
        XCTAssertEqual(fastCDCStrictMask, allOnes << 41, "strict mask must be the top 23 bits")
        XCTAssertEqual(fastCDCLooseMask, allOnes << 45, "loose mask must be the top 19 bits")
        XCTAssertEqual(fastCDCStrictMask.nonzeroBitCount, 23)
        XCTAssertEqual(fastCDCLooseMask.nonzeroBitCount, 19)
        XCTAssertEqual(
            fastCDCStrictMask & fastCDCLooseMask, fastCDCLooseMask,
            "the loose mask must be a subset of the strict mask"
        )
    }

    func testCutBoundsAndDeterminism() {
        XCTAssertTrue(fastCDCEnabled(), "fastcdc-v1 must be the default mode")
        let data = corpusBytes("scionic-fastcdc-v1:test:bounds", 40 << 20)
        let first = cutChunks(data)
        let second = cutChunks(data)
        XCTAssertEqual(first, second, "two cuts of identical data must agree")
        XCTAssertFalse(first.isEmpty)
        var total = 0
        for (index, chunk) in first.enumerated() {
            if index < first.count - 1 {
                XCTAssertGreaterThan(
                    chunk.count, fastCDCMinSize,
                    "interior chunk \(index) is \(chunk.count) bytes; interior chunks must exceed the min"
                )
            }
            XCTAssertLessThanOrEqual(chunk.count, fastCDCMaxSize, "chunk \(index) exceeds the max")
            total += chunk.count
        }
        XCTAssertEqual(total, data.count, "chunks must cover the input exactly")
        let mean = total / first.count
        XCTAssertTrue(
            (1 << 20...4 << 20).contains(mean),
            "mean chunk size \(mean) is outside the [1MiB, 4MiB] sanity band"
        )
    }

    func testStreamingMatchesSliceCutting() throws {
        let lengths = [
            0,
            100,
            fastCDCMinSize,
            fastCDCMinSize + 1,
            fastCDCTargetSize,
            fastCDCMaxSize,
            fastCDCMaxSize + 1,
            3 << 20,
            20 << 20,
        ]
        for length in lengths {
            let data = corpusBytes("scionic-fastcdc-v1:test:stream", length)
            let expected = cutChunks(data)
            var streamed: [Data] = []
            // Awkward partial reads exercise every refill path of the
            // streaming cutter.
            var offset = 0
            let step = 64 * 1024 + 17
            try streamFastCDCChunks(read: { want in
                if offset >= data.count {
                    return Data()
                }
                let take = min(step, min(want, data.count - offset))
                let piece = data.subdata(in: offset..<(offset + take))
                offset += take
                return piece
            }, callback: { chunk, index in
                XCTAssertEqual(index, streamed.count, "length \(length): chunk order")
                streamed.append(chunk)
            })
            XCTAssertEqual(streamed, expected, "length \(length): streaming vs slice cutting")
        }
    }

    func testSmallInputsAreSingleChunks() {
        for length in [1, 100, fastCDCMinSize - 1, fastCDCMinSize] {
            let data = corpusBytes("scionic-fastcdc-v1:test:small", length)
            let chunks = cutChunks(data)
            XCTAssertEqual(chunks.count, 1, "length \(length) must be a single chunk")
            XCTAssertEqual(chunks[0], data)
        }
        XCTAssertTrue(cutChunks(Data()).isEmpty)
    }

    func testConstantBytesStayBounded() {
        // 20 MiB of zeros never matches either mask: every chunk is a forced
        // cut at the max, with the remainder as the tail — pinned by the Go
        // conformance corpus (zeros_20mib: 8 MiB + 8 MiB + 4 MiB).
        let zeros = Data(repeating: 0, count: 20 << 20)
        XCTAssertEqual(cutChunks(zeros).map(\.count), [8 << 20, 8 << 20, 4 << 20])
        let letters = Data(repeating: UInt8(ascii: "a"), count: 20 << 20)
        let letterChunks = cutChunks(letters)
        var total = 0
        for (index, chunk) in letterChunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.count, fastCDCMaxSize)
            if index < letterChunks.count - 1 {
                XCTAssertGreaterThan(chunk.count, fastCDCMinSize)
            }
            total += chunk.count
        }
        XCTAssertEqual(total, letters.count)
    }

    func testInsertReusesMostChunkContent() {
        let base = corpusBytes("scionic-fastcdc-v1:test:reuse", 32 << 20)
        let payload = corpusBytes("scionic-fastcdc-v1:test:reuse-payload", 4096)
        var edited = Data(capacity: base.count + payload.count)
        edited.append(base.subdata(in: 0..<(16 << 20)))
        edited.append(payload)
        edited.append(base.subdata(in: (16 << 20)..<base.count))
        let baseHashes = Set(cutChunks(base).map { sha256Digest($0) })
        let editedChunks = cutChunks(edited)
        let fresh = editedChunks.filter { !baseHashes.contains(sha256Digest($0)) }.count
        XCTAssertGreaterThanOrEqual(fresh, 1, "an insert must produce at least one new chunk")
        XCTAssertLessThanOrEqual(
            fresh, 3,
            "a 4 KiB insert produced \(fresh) of \(editedChunks.count) unseen chunks; " +
            "content-defined chunking should confine an edit to ~1-2 chunks plus resettling"
        )
    }

    func testModeCutSemanticsMatchTheGoCutter() {
        defer { setDefaultChunkSize() }
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9] as [UInt8])

        setChunkSize(4)
        XCTAssertFalse(fastCDCEnabled())
        XCTAssertNil(activeChunkingTag())
        XCTAssertTrue(cutChunks(Data()).isEmpty)
        XCTAssertEqual(
            cutChunks(data),
            [data.subdata(in: 0..<4), data.subdata(in: 4..<8), data.subdata(in: 8..<10)]
        )
        setChunkSize(16)
        XCTAssertEqual(cutChunks(data), [data])

        disableChunking()
        XCTAssertFalse(fastCDCEnabled())
        XCTAssertEqual(cutChunks(data), [data])
        XCTAssertTrue(cutChunks(Data()).isEmpty)

        setDefaultChunkSize()
        XCTAssertTrue(fastCDCEnabled())
        XCTAssertEqual(activeChunkingTag(), chunkingFastCDCV1)
        XCTAssertEqual(chunkSize, defaultChunkSize)
        XCTAssertEqual(cutChunks(data), [data])
    }

    /// The tri-modal empty-file contract, matching Go and Rust exactly:
    /// fastcdc-v1 and legacy FIXED mode emit no chunks for an empty file, so
    /// its leaf carries no content and no content hash; legacy DISABLED mode
    /// stores an explicit empty content buffer (Go's io.ReadAll path). This
    /// port used to emit one empty chunk in fixed mode, which changed the
    /// leaf's CID relative to Go and Rust.
    func testEmptyFileLeafSemanticsAcrossModes() throws {
        defer { setDefaultChunkSize() }
        let root = try ParityTestHelpers.makeTempDir("fastcdc_empty_modes")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try ParityTestHelpers.writeData(ParityTestHelpers.join(root, "empty.bin"), Data())

        setDefaultChunkSize() // fastcdc-v1
        let fastcdcDag = try ScionicMerkleTree.createDag(path: root, timestampRoot: false)
        let fastcdcLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: fastcdcDag, type: .file))
        XCTAssertNil(fastcdcLeaf.content, "fastcdc: empty file leaf must carry no content")
        XCTAssertNil(fastcdcLeaf.contentHash, "fastcdc: empty file leaf must carry no content hash")
        try fastcdcDag.verify()

        setChunkSize(4096) // legacy fixed
        let fixedDag = try ScionicMerkleTree.createDag(path: root, timestampRoot: false)
        let fixedLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: fixedDag, type: .file))
        XCTAssertNil(fixedLeaf.content, "fixed: empty file leaf must carry no content")
        XCTAssertNil(fixedLeaf.contentHash, "fixed: empty file leaf must carry no content hash")
        try fixedDag.verify()

        disableChunking() // legacy disabled: explicit empty buffer
        let disabledDag = try ScionicMerkleTree.createDag(path: root, timestampRoot: false)
        let disabledLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: disabledDag, type: .file))
        XCTAssertEqual(disabledLeaf.content, Data(), "disabled: empty file stores an explicit empty buffer")
        XCTAssertNotNil(disabledLeaf.contentHash, "disabled: explicit empty content is hashed")
        try disabledDag.verify()

        // The two contentless variants agree with each other and differ from
        // the explicit-empty one — the distinction is hash-visible.
        XCTAssertEqual(fastcdcLeaf.hash, fixedLeaf.hash)
        XCTAssertNotEqual(fastcdcLeaf.hash, disabledLeaf.hash)
    }
}
