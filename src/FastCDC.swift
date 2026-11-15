// fastcdc-v1: chunking a file by its content (FastCDC, Xia et al. 2016). It is
// the way a tree's files are chunked. This code and the vectors under
// spec/fastcdc-vectors define its exact bytes, as the Rust library's do.
//
// Chunking at a fixed size (`Chunking.fixed`) is there for tests. A tree says
// in its record which of the two it used, and every file in it is held to that
// when the tree is checked.
//
// Every constant in this file is frozen as fastcdc-v1. A change to a size, a
// mask, a gear entry or the boundary loop would be another way of chunking
// under another name, never a change to this one: two builders give the same
// file the same hash only when both cut at the same bytes.

/// The constants of fastcdc-v1.
public enum FastCDC {
    /// No chunk ends within its first `minSize` bytes, and those bytes are not
    /// hashed. Every chunk but a file's last holds more than this.
    public static let minSize = 512 * 1024
    /// Where the strict mask gives way to the loose one.
    public static let targetSize = 2048 * 1024
    /// The most bytes a chunk may hold. A chunk that no byte ends is cut here.
    public static let maxSize = 8192 * 1024
    /// The top 23 bits of the rolling hash: judges places before `targetSize`.
    public static let strictMask: UInt64 = 0xFFFF_FE00_0000_0000
    /// The top 19 bits: judges places from `targetSize` on.
    public static let looseMask: UInt64 = 0xFFFF_E000_0000_0000
    /// `G[i]` is the first 8 bytes, as a big-endian number, of
    /// `SHA-256(gearSeedPrefix + byte i)`.
    public static let gearSeedPrefix = "scionic-fastcdc-v1:gear:"
}

/// The frozen fastcdc-v1 gear table, derived exactly from
/// `FastCDC.gearSeedPrefix`. A test derives every entry again.
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

/// How many bytes a hash remembers. Every step shifts it one bit to the left,
/// so a byte has left it for good 64 steps later: the hash after a byte is made
/// of that byte and the 63 before it, and of nothing else.
private let gearWindow = 64

/// How many bytes each of the four hashes rolls over in a round.
private let stride = 4096

@inline(__always)
private func roll(_ hash: UInt64, _ byte: UInt8, _ gear: UnsafePointer<UInt64>) -> UInt64 {
    (hash &<< 1) &+ gear[Int(byte)]
}

/// The length of the next chunk cut from `data`. The caller makes sure that
/// `data` is either at least `FastCDC.maxSize` bytes long or ends where the
/// input does: then the cut is final, since it never depends on bytes past
/// the most a chunk may hold.
///
/// The definition is one byte a step: the rolling hash starts at zero for every
/// chunk, the first `minSize` bytes are skipped without hashing, each later
/// byte `b` turns the hash `h` into `(h << 1) + G[b]` with the overflow
/// dropped, and the first byte `i` whose hash has no bit of the mask set ends
/// the chunk after it (length `i + 1`). The strict mask judges places below
/// `targetSize` and the loose mask the ones from it on. This gives exactly that,
/// with four hashes at work side by side; the tests hold it to the plain loop.
func fastCDCBoundary(_ data: UnsafeRawBufferPointer) -> Int {
    let n = data.count
    if n <= FastCDC.minSize {
        return n
    }
    let limit = min(n, FastCDC.maxSize)
    let normal = min(FastCDC.targetSize, limit)
    let bytes = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
    return fastCDCGear.withUnsafeBufferPointer { table in
        let gear = table.baseAddress!
        var h: UInt64 = 0
        if let cut = scan(bytes, gear, from: FastCDC.minSize, to: normal, mask: FastCDC.strictMask, h: &h) {
            return cut
        }
        if let cut = scan(bytes, gear, from: normal, to: limit, mask: FastCDC.looseMask, h: &h) {
            return cut
        }
        return limit
    }
}

/// Rolls the hash `h` over `data[from..<to]`, and gives the length that the
/// first matching byte ends a chunk at. Without a match, `h` is left as the hash
/// after byte `to - 1`.
///
/// One hash can take a byte only when it is done with the byte before, and that
/// wait is what bounds a plain loop. So four stretches that follow one another
/// are rolled over side by side, a byte of each in turn. The first hash carries
/// on from where it was. Each of the others starts 64 bytes before its own
/// stretch, which is all a hash remembers, so it holds what a single hash would
/// hold there. When any of the four matches, the first one goes on alone to the
/// first match in the order of the bytes.
///
/// `from` is at least `FastCDC.minSize`, where hashing begins: a stretch that is
/// not the first one always has 64 hashed bytes before it.
@inline(__always)
private func scan(
    _ data: UnsafePointer<UInt8>,
    _ gear: UnsafePointer<UInt64>,
    from: Int,
    to: Int,
    mask: UInt64,
    h: inout UInt64
) -> Int? {
    var hash = h
    var at = from
    while to - at >= 4 * stride {
        // One block of four stretches, read through one pointer: the four
        // hashes and what they need then fit into the machine's registers.
        let block = data + at
        var h0 = hash
        var h1: UInt64 = 0
        var h2: UInt64 = 0
        var h3: UInt64 = 0
        for i in (stride - gearWindow)..<stride {
            h1 = roll(h1, block[i], gear)
            h2 = roll(h2, block[i + stride], gear)
            h3 = roll(h3, block[i + 2 * stride], gear)
        }
        // Two bytes of each stretch a round, so that the loop's own counting is
        // a smaller part of the work. The stride is even.
        var steps = 0
        var step = 0
        while step < stride {
            h0 = roll(h0, block[step], gear)
            h1 = roll(h1, block[step + stride], gear)
            h2 = roll(h2, block[step + 2 * stride], gear)
            h3 = roll(h3, block[step + 3 * stride], gear)
            if h0 & mask == 0 || h1 & mask == 0 || h2 & mask == 0 || h3 & mask == 0 {
                steps = step + 1
                break
            }
            h0 = roll(h0, block[step + 1], gear)
            h1 = roll(h1, block[step + stride + 1], gear)
            h2 = roll(h2, block[step + 2 * stride + 1], gear)
            h3 = roll(h3, block[step + 3 * stride + 1], gear)
            if h0 & mask == 0 || h1 & mask == 0 || h2 & mask == 0 || h3 & mask == 0 {
                steps = step + 2
                break
            }
            step += 2
        }
        if steps != 0 {
            if h0 & mask == 0 {
                return at + steps
            }
            // A later stretch matched. An earlier byte may match too, so the
            // first hash goes on alone, and stops at the first match there is.
            hash = h0
            at += steps
            break
        }
        hash = h3
        at += 4 * stride
    }
    while at < to {
        hash = roll(hash, data[at], gear)
        at += 1
        if hash & mask == 0 {
            return at
        }
    }
    h = hash
    return nil
}

/// The boundary as it is written down: one byte a step. For the tests.
func fastCDCBoundaryPlain(_ data: UnsafeRawBufferPointer) -> Int {
    let n = data.count
    if n <= FastCDC.minSize {
        return n
    }
    let limit = min(n, FastCDC.maxSize)
    let normal = min(FastCDC.targetSize, limit)
    var h: UInt64 = 0
    for i in FastCDC.minSize..<normal {
        h = (h &<< 1) &+ fastCDCGear[Int(data[i])]
        if h & FastCDC.strictMask == 0 {
            return i + 1
        }
    }
    for i in normal..<max(normal, limit) {
        h = (h &<< 1) &+ fastCDCGear[Int(data[i])]
        if h & FastCDC.looseMask == 0 {
            return i + 1
        }
    }
    return limit
}

/// How a tree's files are split into chunks.
public struct Chunking: Hashable, Sendable, CustomStringConvertible {
    /// The size of every chunk but a file's last, or nil for fastcdc-v1.
    public let fixedSize: UInt32?

    private init(fixedSize: UInt32?) {
        self.fixedSize = fixedSize
    }

    /// By content: chunks of more than 512 KiB, about 2 MiB on average, and
    /// 8 MiB at most. Only a file's last chunk may be smaller.
    public static let fastCDCv1 = Chunking(fixedSize: nil)

    /// Every chunk but a file's last holds exactly `size` bytes, of 1 byte to
    /// 8 MiB. For tests.
    public static func fixed(_ size: UInt32) throws -> Chunking {
        guard size >= 1, Int(size) <= Scionic.maxChunkBytes else {
            throw invalid("a fixed chunk size is not 1 byte to 8 MiB")
        }
        return Chunking(fixedSize: size)
    }

    /// How a record says this: `fastcdc-v1`, or `fixed-` and the size.
    public var tag: String {
        if let size = fixedSize {
            return "fixed-\(size)"
        }
        return Scionic.chunkingFastCDCv1
    }

    /// Reads what a record says. A size is written in digits with no zero in
    /// front, so each way of chunking has one spelling.
    public init<Tag: Collection>(tag: Tag) throws where Tag.Element == UInt8 {
        let unknown = invalid("a record names a way of chunking that is not known")
        if tag.elementsEqual(Scionic.chunkingFastCDCv1.utf8) {
            self = .fastCDCv1
            return
        }
        let prefix = Array("fixed-".utf8)
        guard tag.starts(with: prefix) else {
            throw unknown
        }
        let digits = Array(tag.dropFirst(prefix.count))
        guard !digits.isEmpty, digits.count <= 7, digits[0] != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            throw unknown
        }
        let size = digits.reduce(UInt32(0)) { $0 * 10 + UInt32($1 - UInt8(ascii: "0")) }
        guard let chunking = try? Chunking.fixed(size) else {
            throw unknown
        }
        self = chunking
    }

    public var description: String { tag }

    /// Whether a chunk of `length` bytes fits, as a file's last chunk or as one
    /// before it.
    public func checkLength(_ length: UInt32, isLast: Bool) throws {
        let length = Int(length)
        let fits: Bool
        if let size = fixedSize.map(Int.init) {
            fits = isLast ? (1...size).contains(length) : length == size
        } else {
            fits = (1...FastCDC.maxSize).contains(length) && (isLast || length > FastCDC.minSize)
        }
        guard fits else {
            throw invalid("a chunk has a length that the tree's way of chunking does not give")
        }
    }

    /// The fewest and the most chunks that a file of `size` bytes can have.
    public func countBounds(size: UInt64) -> (fewest: UInt64, most: UInt64) {
        if size == 0 {
            return (0, 0)
        }
        if let chunk = fixedSize {
            let count = (size - 1) / UInt64(chunk) + 1
            return (count, count)
        }
        return ((size - 1) / UInt64(FastCDC.maxSize) + 1, (size - 1) / (UInt64(FastCDC.minSize) + 1) + 1)
    }

    /// Whether a file of `size` bytes can have `count` chunks.
    public func checkCount(size: UInt64, count: UInt64) throws {
        let bounds = countBounds(size: size)
        guard (bounds.fewest...bounds.most).contains(count) else {
            throw invalid("a file has a number of chunks that its size does not allow")
        }
    }

    /// The lengths of the chunks that `data` is cut into, in order. No bytes
    /// give no chunks.
    ///
    /// A caller that holds a file in memory cuts it with this, so that every
    /// builder cuts the same bytes at the same places.
    public func cutLengths(_ data: UnsafeRawBufferPointer) -> [Int] {
        var lengths: [Int] = []
        if let size = fixedSize.map(Int.init) {
            var offset = 0
            while offset < data.count {
                let length = min(size, data.count - offset)
                lengths.append(length)
                offset += length
            }
            return lengths
        }
        lengths.reserveCapacity(data.count / FastCDC.targetSize + 1)
        var offset = 0
        while offset < data.count {
            let length = fastCDCBoundary(UnsafeRawBufferPointer(rebasing: data[offset...]))
            lengths.append(length)
            offset += length
        }
        return lengths
    }

    /// Cuts `data` into chunks: parts of `data`, in order, and nothing copied.
    public func cut(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        let lengths = data.withUnsafeBytes { cutLengths($0) }
        var chunks: [ArraySlice<UInt8>] = []
        chunks.reserveCapacity(lengths.count)
        var offset = 0
        for length in lengths {
            chunks.append(data[offset..<(offset + length)])
            offset += length
        }
        return chunks
    }
}

/// What a chunker's window holds when it starts on its first stream. The
/// window grows only as a stream turns out to be longer, so a small file never
/// costs a large window.
private let windowStart = 64 * 1024

/// The most chunks of a fixed size that are handed on at a time.
private let fixedChunksAtATime = 1024

/// Cuts a stream into chunks, holding a window of it and no more. One chunker
/// serves many files, one after another, with the same window.
final class StreamChunker {
    private var window: UnsafeMutableRawBufferPointer = UnsafeMutableRawBufferPointer(start: nil, count: 0)

    init() {}

    deinit {
        window.deallocate()
    }

    /// Makes the window longer: twice as long, and never longer than `room`.
    private func grow(room: Int) throws {
        let length = min(max(window.count * 2, windowStart), room)
        guard length > window.count else {
            return
        }
        let larger = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 16)
        if window.count > 0 {
            larger.copyMemory(from: UnsafeRawBufferPointer(window))
        }
        window.deallocate()
        window = larger
    }

    /// Reads with `read` until it gives no more bytes, and hands the chunks to
    /// `onChunks` in order: each time, all the chunks that the window holds
    /// whole. The chunks are lent only for the call.
    ///
    /// `room` is the most bytes the window may hold. It always holds one chunk
    /// of the longest kind; with more room, more chunks are handed on at a
    /// time, and fewer bytes are moved to make room for the next ones.
    ///
    /// Where a chunk ends is settled only once the window holds
    /// `FastCDC.maxSize` bytes from the chunk's start, or the input has ended.
    /// That is what makes chunking a stream the same as chunking the whole of
    /// it at once.
    func cut(
        _ chunking: Chunking,
        room asked: Int,
        read: (UnsafeMutableRawBufferPointer) throws -> Int,
        onChunks: ([UnsafeRawBufferPointer]) throws -> Void
    ) throws {
        let longest: Int
        let room: Int
        if let size = chunking.fixedSize.map(Int.init) {
            longest = size
            let (most, overflow) = size.multipliedReportingOverflow(by: fixedChunksAtATime)
            room = max(min(asked, overflow ? Int.max : most), size)
        } else {
            longest = FastCDC.maxSize
            room = max(asked, FastCDC.maxSize)
        }
        var filled = 0
        var ended = false
        while true {
            while !ended && filled < room {
                if filled == window.count {
                    try grow(room: room)
                }
                let end = min(window.count, room)
                let count = try read(UnsafeMutableRawBufferPointer(rebasing: window[filled..<end]))
                if count < 0 || count > end - filled {
                    throw ScionicError.invariant("a reader gave more bytes than it was asked for")
                }
                if count == 0 {
                    ended = true
                } else {
                    filled += count
                }
            }
            var chunks: [UnsafeRawBufferPointer] = []
            var start = 0
            while start < filled {
                let rest = UnsafeRawBufferPointer(rebasing: window[start..<filled])
                if !ended && rest.count < longest {
                    break // not settled: fill the window again first
                }
                let length = chunking.fixedSize == nil ? fastCDCBoundary(rest) : min(rest.count, longest)
                chunks.append(UnsafeRawBufferPointer(rebasing: rest[0..<length]))
                start += length
            }
            if !chunks.isEmpty {
                try onChunks(chunks)
            }
            if start > 0 && start < filled {
                window.baseAddress!.copyMemory(from: window.baseAddress! + start, byteCount: filled - start)
            }
            filled -= start
            if ended && filled == 0 {
                return
            }
        }
    }
}
