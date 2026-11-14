// Big-endian numbers in and out of bytes, as the format writes them.

extension Array where Element == UInt8 {
    @inline(__always)
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    @inline(__always)
    mutating func appendU32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func appendU64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func append(_ hash: Hash) {
        hash.withUnsafeBytes { append(contentsOf: $0) }
    }
}

/// Reads numbers and bytes off the front of a run of bytes, strictly: a read
/// past the end is an error, and so are bytes left over when the reader is
/// finished.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var position: Int
    let end: Int
    /// What is being read, for errors: "a file's list", "a record".
    let what: String

    init(_ bytes: [UInt8], what: String) {
        self.bytes = bytes
        self.position = 0
        self.end = bytes.count
        self.what = what
    }

    /// Reads `bytes[from..<to]` only.
    init(_ bytes: [UInt8], from: Int, to: Int, what: String) {
        precondition(0 <= from && from <= to && to <= bytes.count)
        self.bytes = bytes
        self.position = from
        self.end = to
        self.what = what
    }

    var remaining: Int { end - position }
    var isEmpty: Bool { position == end }

    /// The next `count` bytes, as a part of the bytes read: nothing is copied.
    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else {
            throw invalid("\(what) is cut short")
        }
        let part = bytes[position..<(position + count)]
        position += count
        return part
    }

    /// Skips `count` bytes.
    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw invalid("\(what) is cut short")
        }
        position += count
    }

    @inline(__always)
    private mutating func need(_ count: Int) throws -> Int {
        guard count <= remaining else {
            throw invalid("\(what) is cut short")
        }
        let at = position
        position += count
        return at
    }

    mutating func u8() throws -> UInt8 {
        bytes[try need(1)]
    }

    mutating func u16() throws -> UInt16 {
        let at = try need(2)
        return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    mutating func u32() throws -> UInt32 {
        let at = try need(4)
        return bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    mutating func u64() throws -> UInt64 {
        let at = try need(8)
        return bytes.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
    }

    mutating func hash() throws -> Hash {
        let at = try need(32)
        return bytes.withUnsafeBytes { Hash(rawBytes: UnsafeRawBufferPointer(rebasing: $0[at..<(at + 32)])) }
    }

    /// Everything must have been read.
    func finish() throws {
        guard isEmpty else {
            throw invalid("\(what) has bytes after its end")
        }
    }
}

/// Whether `a` sorts before `b`, byte by byte, as the format orders names.
@inline(__always)
func bytesLess<A: Collection, B: Collection>(_ a: A, _ b: B) -> Bool
    where A.Element == UInt8, B.Element == UInt8 {
    a.lexicographicallyPrecedes(b)
}
