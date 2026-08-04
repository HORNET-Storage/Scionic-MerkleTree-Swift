// FastCDC.swift — fastcdc-v1 content-defined chunking, the DEFAULT chunking
// mode for all new trees.
//
// Ported line-for-line from the Go reference's dag/fastcdc.go and
// dag/fastcdc_gear.go (normative spec: the Go repo's docs/fastcdc-v1.md; the
// algorithm is FastCDC, Xia et al. 2016).
//
// Fixed-size chunking (setChunkSize / disableChunking) remains available as
// the legacy mode; the committed spec-vector corpus and older callers pin it
// explicitly. Verification is chunking-agnostic — no verifier re-chunks — so
// trees cut by either mode verify identically everywhere.
//
// Every constant in this file is NORMATIVE and frozen as fastcdc-v1. Any
// change — a size, a mask, a gear entry, an off-by-one in the boundary loop —
// is a NEW chunking version tag, never a mutation: producers only dedup
// against each other when every SDK cuts bit-identical boundaries, and a
// divergent implementation produces valid-looking trees that never dedup,
// detectable only by the conformance vectors under spec/fastcdc-vectors.

import Foundation

// MARK: - Frozen fastcdc-v1 Constants

/// Cut-point skipping floor: no boundary test runs inside the first
/// `fastCDCMinSize` bytes of a chunk, and those bytes are not hashed at all.
/// Interior chunks are therefore at least `fastCDCMinSize + 1` bytes; only a
/// final tail chunk may be smaller.
public let fastCDCMinSize = 512 * 1024

/// Normalization switch: the strict mask judges positions before it, the
/// loose mask after it, squeezing the chunk-size distribution toward the
/// target. It matches the legacy fixed default (`defaultChunkSize`), so leaf
/// counts and stats stay in the same ballpark across the mode change.
public let fastCDCTargetSize = 2048 * 1024

/// Forced-cut ceiling. It exists to bound worst-case chunk size (record
/// framing, transport batching), not as a size anyone chooses: with
/// normalized chunking a forced cut is rare, degenerate-content territory.
public let fastCDCMaxSize = 8192 * 1024

/// Selects the top 23 bits of the rolling hash (boundary ⇔ h < 2^41). Used
/// for positions before `fastCDCTargetSize`.
public let fastCDCStrictMask: UInt64 = 0xFFFF_FE00_0000_0000

/// Selects the top 19 bits (boundary ⇔ h < 2^45). Used for positions at or
/// after `fastCDCTargetSize`. The loose mask is a subset of the strict mask.
public let fastCDCLooseMask: UInt64 = 0xFFFF_E000_0000_0000

/// Frozen derivation seed for the gear table below:
///
///     G[i] = u64be(SHA-256(fastCDCGearSeedPrefix ++ byte(i))[0..<8])
///
/// where byte(i) is the single raw byte with value i. The regeneration test
/// re-derives every entry and fails on drift.
public let fastCDCGearSeedPrefix = "scionic-fastcdc-v1:gear:"

// MARK: - Root-Tag Vocabulary

// The chunking tag lives in the root leaf's additionalData and informs
// producers and delta tooling only. Verification MUST NOT re-chunk;
// verifiers ignore the tag entirely.

/// The additionalData key carrying the chunking tag.
public let chunkingTagKey = "chunking"

/// Tags roots cut with fastcdc-v1.
public let chunkingFastCDCV1 = "fastcdc-v1"

/// The implied value when the tag is absent: every pre-fastcdc v2 tree was
/// cut fixed-size. Producers never stamp it.
public let chunkingFixed2M = "fixed-2m"

// MARK: - Active Chunking Mode

/// Selects the active producer chunking mode. Like `chunkSize` and
/// `batchSize` it is a process-global producer setting: configure it before
/// createDag, not concurrently with one. `setChunkSize` switches to the
/// legacy fixed mode; `setDefaultChunkSize` restores this default.
/// (Mirrors Go's `chunkingFastCDC`.)
var chunkingFastCDC = true

/// Reports whether new DAGs are cut with fastcdc-v1.
public func fastCDCEnabled() -> Bool {
    return chunkingFastCDC
}

/// Returns the root-tag value for the active mode: `chunkingFastCDCV1` under
/// fastcdc-v1, or nil under the legacy fixed modes (absent tag ⇒ fixed-2m
/// per the spec). Nil is the Swift mirror of Go's empty-string sentinel.
public func activeChunkingTag() -> String? {
    return chunkingFastCDC ? chunkingFastCDCV1 : nil
}

/// Returns additionalData plus the active chunking tag. Dictionaries are
/// value types, so the caller's dictionary is never mutated. The library
/// owns this key: a caller-supplied "chunking" value is overwritten, because
/// a tag that does not reflect how the tree was actually cut breaks delta
/// tooling. Under the legacy modes the input is returned unchanged — nil
/// stays nil, exactly like Go's `withChunkingTag`.
func withChunkingTag(_ additionalData: [String: String]?) -> [String: String]? {
    guard let tag = activeChunkingTag() else {
        return additionalData
    }
    var merged = additionalData ?? [:]
    merged[chunkingTagKey] = tag
    return merged
}

// MARK: - Gear Table

/// The frozen gear table, derived from `fastCDCGearSeedPrefix` (see above).
/// Byte-identical to the Go reference's dag/fastcdc_gear.go and the Rust
/// port's table.
let fastCDCGear: [UInt64] = [
    0x947e4e1b8bedab5d, 0xd7d7f340329c706e, 0x24b4933c9d4b8dbc, 0x55c3cff8b195ba49,
    0xa36a40a32a15eb96, 0x8897e6f568db999a, 0x947a231bb313926d, 0xe7e926bd79e72444,
    0x64ca6fd402ccab41, 0x22380ac762595371, 0xa1027491350cae72, 0xf3538e28c8606995,
    0x35340c7c2bbf517c, 0xf4673c048041926c, 0x619d36e34045ed48, 0x62f7eea257e5fa53,
    0xf6592b0a28cbfe72, 0x57dbf4bc9c6b6c13, 0x4570eda97a46bcd7, 0xe700b4d777b13368,
    0xfeaa0ed12db1fb1e, 0x5eaaa35f803749c5, 0x98d4aaf60762ce22, 0x57e5c72e8ca35383,
    0xfa73cdf93e8a0aa2, 0x5ff08d8005821eaf, 0x22bfbfb0909e5a97, 0xaf640461642bc5ec,
    0xf52f62b326a87782, 0x0b48fe2026c4d431, 0xe32da4ee6ee83556, 0xf6fb7c97d1347f1e,
    0xd8db48db0fc909b1, 0x61a094811e1147be, 0x55212f91cebc2fd7, 0x3cc046faa63bd6b6,
    0x6e58acaa5d253fc2, 0xdabaafb8773dd9df, 0x97e17884746879ba, 0xba04b1babdf2b315,
    0xebbba32ca84e54d4, 0xf5e823b31a74a250, 0x3a53c93b59c25ac1, 0xbbeef3c363a99a40,
    0xa43fee0764787596, 0x13afe9712464954f, 0xfb8c8b920ee55c9e, 0xd4d7bf30b1a6a5ad,
    0x0389222afdca4fd5, 0xe9ab9fb7f5155a62, 0x9f77717172866e25, 0xd2ad3637f74249a5,
    0x50bbdad70cdcd17c, 0xec8f7f90e393a183, 0x1446de505ccf5c72, 0xe6e78a5e4b304fb6,
    0x0bbe404684ecdad1, 0x532bcb63c95a255d, 0xd887c18de16cf115, 0xf513ad7d0f7d3d50,
    0x849baac5ecdefbdb, 0x94a4f2fbbcca6083, 0x1b3c9424f9385894, 0xe11e8a43c22fabcb,
    0x9b4b010fc51f21dc, 0x6acd6dbfdf0d9580, 0x7ff7afdb56a0cabf, 0x2ca318014a93f66f,
    0x903803b30226b845, 0xd706e07a902ffcf4, 0x1e43989c9177836a, 0x1450b82ebfeb59be,
    0x0317972865643dc9, 0x20d89fae677a1a46, 0x13afa6f5de7d8bc7, 0x1365198f21449085,
    0xaf159551b9609008, 0xc77a9ae105ce78ce, 0x5f6c8e2d03eb54dc, 0x276ff2550d88ac9f,
    0xa9a03f05b8ca6378, 0x2ee9d93e36176ace, 0x96f94afebcb129f1, 0x8a180b184c6c0c2c,
    0xfa8c5698643f71e4, 0x6dae6ffbcc920ed9, 0xb51d5e1420ac4477, 0xf96f4bda00bebd4b,
    0x835c221df076b64f, 0x6f1d8cb095611348, 0x519baf5ef53f2ccc, 0xf1756553b94e6fd7,
    0x794c84868fdfa25d, 0x5bb0477715cb330d, 0xc0480a057f24d19a, 0xb49ff580892d857f,
    0x4390cbc9493cd65e, 0x4501cfd187cdfaa1, 0xffa17ec6bed4ece5, 0x974516ddd0070b5d,
    0x6e2e1d0829952e10, 0xaf09891926e64ecc, 0xec238b26dd8650f4, 0x003af629de3d5d67,
    0x5f650eb277966586, 0x5acee337d875e529, 0xb768d8c2fd5074de, 0xf7ed06da4a4e2ee7,
    0xfaf4f98b5e203cce, 0xec9aea5b69f1c7c6, 0x210077754e20fa0f, 0x0beb1e323cb5510d,
    0x0e53d51183d4fe31, 0x006474795bf9118a, 0xd4b6d7c83ce5f2db, 0x42284ffa1d364d86,
    0x059c41476b5a023e, 0xdce31ea609858492, 0xd5bb4b3f8fb4c91d, 0x497195b5e4a4edc8,
    0x7d18c40f80f16a55, 0x9e4759761b570c17, 0x6fe3fb1dad1caf51, 0xd4f2b14506aae434,
    0xf2aaedad0a75b8f9, 0x8800c63677d46e91, 0x3669e9c07cdd7731, 0x396b68f5f4a95f57,
    0xaa52f9224a19c939, 0x74d1d3ad35a47f39, 0xd02dead3f0370ad1, 0x6f6f5e39506d8dd3,
    0xdd91c64473a67fad, 0x912c5a1ea387c83c, 0x0f1aef548e375e08, 0x5915126ae7ef44e5,
    0x4020e3d9b310f006, 0x57d3f19162586ae5, 0x0ec8f9bf9db952df, 0x234b45cf1ad3dece,
    0xc3439843e92ae994, 0xd6a5719e68c9f484, 0xb4c1920d525d8342, 0xb27eb38f9bbe448d,
    0x9be1ce0459d5c299, 0x4aa52d6a2dbf8342, 0x9851857f62521d37, 0x457947691df8e1fa,
    0x123ef433bc6ae855, 0x45437f1d09980d29, 0x83d6c5a9df253dac, 0xe0d309d01910481c,
    0xf5c31ed8759b25f3, 0x771c0d3936a0d986, 0x487038360bcb3235, 0x8b21d49aed2642e6,
    0xefaaeca49be99218, 0xa463929852ae6bcc, 0x9cfecd6e80346297, 0xdcb4fb0875840689,
    0x37c021d3c8e21186, 0x497f8574675b0d6a, 0x63ff7e7711d33f63, 0x27ceee2fcc031a44,
    0x77b6ec906259e727, 0xaa6454644dccc7dc, 0xa97809bb81de4c81, 0xa92caa6f12da83e6,
    0x419ba0ced90afe95, 0xc1a53002045d97de, 0xb656c2ff7d936018, 0xce49ab8e335c711b,
    0xb6f7f1f1faef85be, 0xc7fc1e0121f1f24e, 0x207f2299674cc436, 0x88ae73e046435d4a,
    0xda8b37dfd93f6cf2, 0xf8bed85aeb4de430, 0x91a05c5a842d2d3e, 0xba4acf82afc1adab,
    0x6604af724f5a2613, 0xe7487d9966306e33, 0xc8f25c01a080b6f8, 0x2579070bb841d4ea,
    0x9d0436b67a346b82, 0xddf70ae38d392e1d, 0x82fc34556533ef4e, 0xc1666e597f289225,
    0x292f47b7b03c0ad8, 0xe917418a9c71a420, 0x2512d2de56ee6abc, 0xaee5398dbcefd1a9,
    0xfd22f9171720f863, 0xdaa15260adf7ee0c, 0x8ac4120e5fca515b, 0x50c57f96eac726cb,
    0x6a8204b4b79797af, 0x7466e7a4f5d03674, 0x5cb8d6f12355cad5, 0x8120ce60387b354c,
    0x35a581514dba45d5, 0x2943845f6f208780, 0x6b5dcf7ec3a3f226, 0xbdcb9125a6c569ce,
    0x48cf3a90e9f40ca0, 0xdc147857a9b243ab, 0xcf02699bfa87d53e, 0x5f764f21da6ebd9e,
    0xa33c8b10a66ad086, 0x67a21420306440f6, 0x3227f62c1550edf1, 0xf075bc356a5a6c19,
    0x692445ed785b7fee, 0xbdc8aac2413c5869, 0x9ba4cb61288e442e, 0xd595279bb31b949e,
    0x128284fde7e3c4f9, 0x1f78bc1a35436eb8, 0xd78586033f026e98, 0xff65419e1caad205,
    0x2121853fca84902d, 0x1f509792e8676c6f, 0x071efae5e5c7cdba, 0xdf9fbe86bb672b62,
    0x2a48e13feb8155d1, 0x362d3079f581cc21, 0x82d1d37ef9fed7d7, 0xfeb8fcbf0d0f56a8,
    0x1cd4673b1aa2e903, 0x7361c495b3516d42, 0x72b341a59b0beec5, 0xc87496bf153d4294,
    0xb180301df83ddd18, 0xc26006a95f083463, 0x140390533647c3c7, 0xc617932041cccb0e,
    0x7afb61832b5a47f6, 0x982f9e423b8ec593, 0xcd3da2d1fb9f4b32, 0x9cf5b507ed12f70a,
    0xafeea67eb17c3ecb, 0x29bde8df040ac225, 0xec8826f6677ae75c, 0xf3ee4e78d7ec22ad,
    0x73c39d59142cf6be, 0x79ad4c76a58450e1, 0xfeb76f05f4b5266d, 0x5c661848895afeb6,
    0xa3d419256671c19e, 0xfeab6e3349a9aee8, 0x8947c9860ea0a859, 0x88d04b136b03be5d,
    0x6d3315241ab6bea2, 0x9574ce7f94a7374d, 0xf9f0bc62e740e03b, 0x628f935ad9cce8d5,
]

// MARK: - Boundary

/// Returns the length of the next chunk cut from `data`. The caller
/// guarantees `data` is either at least `fastCDCMaxSize` bytes long or ends
/// at EOF — under that contract the decision is final: a boundary can never
/// depend on bytes past the forced maximum.
///
/// This loop IS the normative fastcdc-v1 boundary definition. The rolling
/// hash starts at zero for every chunk, bytes [0, fastCDCMinSize) are
/// skipped without hashing, arithmetic is wrapping UInt64 (`&<<` / `&+`,
/// matching Go's silently-wrapping uint64), and a match on byte index i cuts
/// AFTER that byte (length i + 1).
func fastCDCBoundary(_ data: UnsafeBufferPointer<UInt8>) -> Int {
    let n = data.count
    if n <= fastCDCMinSize {
        return n
    }
    let limit = min(n, fastCDCMaxSize)
    let normal = min(fastCDCTargetSize, limit)
    let base = data.baseAddress! // n > fastCDCMinSize > 0 here
    var h: UInt64 = 0
    var i = fastCDCMinSize
    while i < normal {
        h = (h &<< 1) &+ fastCDCGear[Int(base[i])]
        if h & fastCDCStrictMask == 0 {
            return i + 1
        }
        i += 1
    }
    while i < limit {
        h = (h &<< 1) &+ fastCDCGear[Int(base[i])]
        if h & fastCDCLooseMask == 0 {
            return i + 1
        }
        i += 1
    }
    return limit
}

// MARK: - Public Cutter

/// Splits `data` into chunks under the ACTIVE chunking mode: fastcdc-v1 by
/// default, or fixed-size slicing after setChunkSize/disableChunking. Empty
/// input returns an empty array.
///
/// This is the public cutter for producers that hold content in memory:
/// cutting through the library is what keeps every producer slicing
/// identical content into identical chunks — per-workload chunking would
/// silently break cross-context dedup. It mirrors the Go repo's mode-aware
/// `dag.CutChunks` (Go returns aliasing subslices; Swift returns independent
/// `Data` copies, which changes nothing hashable).
public func cutChunks(_ data: Data) -> [Data] {
    if data.isEmpty {
        return []
    }
    if !chunkingFastCDC {
        if chunkSize <= 0 || data.count <= chunkSize {
            return [data]
        }
        var chunks: [Data] = []
        chunks.reserveCapacity((data.count + chunkSize - 1) / chunkSize)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunks.append(data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
            offset = end
        }
        return chunks
    }
    // fastcdc-v1: compute chunk end offsets against the raw buffer first,
    // then materialize owned Data values.
    var ends: [Int] = []
    ends.reserveCapacity(data.count / fastCDCTargetSize + 1)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let bytes = raw.bindMemory(to: UInt8.self)
        var offset = 0
        while offset < bytes.count {
            let cut = fastCDCBoundary(UnsafeBufferPointer(rebasing: bytes[offset...]))
            offset += cut
            ends.append(offset)
        }
    }
    var chunks: [Data] = []
    chunks.reserveCapacity(ends.count)
    var start = 0
    for end in ends {
        chunks.append(data.subdata(in: (data.startIndex + start)..<(data.startIndex + end)))
        start = end
    }
    return chunks
}

// MARK: - Streaming

/// Streams a file's chunks under the active chunking mode. This is the
/// single dispatch point the DAG builders cut through (mirrors Go's
/// `streamChunksFromFile`).
func streamChunksFromFile(fullPath: String, callback: (Data, Int) throws -> Void) throws {
    if chunkingFastCDC {
        try streamFastCDCFile(fullPath: fullPath, callback: callback)
    } else {
        try streamFileChunks(fullPath: fullPath, chunkSize: chunkSize, callback: callback)
    }
}

func streamFastCDCFile(fullPath: String, callback: (Data, Int) throws -> Void) throws {
    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: fullPath))
    defer { try? fileHandle.close() }
    try streamFastCDCChunks(read: { want in
        try fileHandle.read(upToCount: want) ?? Data()
    }, callback: callback)
}

/// Reads through `read` and emits fastcdc-v1 chunks in order. Each emitted
/// chunk is an exact-size allocation owned by the callback — leaves retain
/// chunk content, so chunks must never alias the reusable window. Transient
/// memory is one `fastCDCMaxSize` window per concurrent call (parallel
/// creation: one per active worker file).
///
/// `read(want)` returns at most `want` bytes; an empty result means EOF.
///
/// Windowing rule (normative): a boundary decision is final if and only if
/// the window holds `fastCDCMaxSize` bytes or the input is exhausted — which
/// is what makes streaming equal whole-buffer cutting, byte for byte.
func streamFastCDCChunks(
    read: (Int) throws -> Data,
    callback: (Data, Int) throws -> Void
) throws {
    var window = [UInt8](repeating: 0, count: fastCDCMaxSize)
    var filled = 0
    var index = 0
    var eof = false
    while true {
        while filled < window.count && !eof {
            let piece = try read(window.count - filled)
            if piece.isEmpty {
                eof = true
            } else {
                precondition(
                    piece.count <= window.count - filled,
                    "read closure returned more bytes than requested"
                )
                piece.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    window.withUnsafeMutableBufferPointer { buffer in
                        buffer.baseAddress!.advanced(by: filled)
                            .update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
                    }
                }
                filled += piece.count
            }
        }
        if filled == 0 {
            return
        }
        while filled == window.count || (eof && filled > 0) {
            let cut = window.withUnsafeBufferPointer { buffer in
                fastCDCBoundary(UnsafeBufferPointer(rebasing: buffer[0..<filled]))
            }
            try callback(Data(window[0..<cut]), index)
            index += 1
            if cut < filled {
                // Shift the remainder to the front. update(from:count:) is
                // documented overlap-safe (memmove semantics).
                window.withUnsafeMutableBufferPointer { buffer in
                    let base = buffer.baseAddress!
                    base.update(from: base + cut, count: filled - cut)
                }
            }
            filled -= cut
            if !eof {
                break // refill the window before judging the next boundary
            }
        }
        if eof && filled == 0 {
            return
        }
    }
}
