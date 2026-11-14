/// Writes big-endian numbers and bytes into memory that the caller has made
/// large enough, for the small things that are hashed: a leaf, a fork, the
/// hash of a file or a folder. Nothing is allocated.
struct RawWriter {
    private let base: UnsafeMutableRawPointer
    private(set) var count = 0

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        base = buffer.baseAddress!
    }

    @inline(__always)
    mutating func u8(_ value: UInt8) {
        base.storeBytes(of: value, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    @inline(__always)
    mutating func u16(_ value: UInt16) {
        base.storeBytes(of: value.bigEndian, toByteOffset: count, as: UInt16.self)
        count += 2
    }

    @inline(__always)
    mutating func u32(_ value: UInt32) {
        base.storeBytes(of: value.bigEndian, toByteOffset: count, as: UInt32.self)
        count += 4
    }

    @inline(__always)
    mutating func u64(_ value: UInt64) {
        base.storeBytes(of: value.bigEndian, toByteOffset: count, as: UInt64.self)
        count += 8
    }

    @inline(__always)
    mutating func hash(_ hash: Hash) {
        u64(hash.w0)
        u64(hash.w1)
        u64(hash.w2)
        u64(hash.w3)
    }

    @inline(__always)
    mutating func bytes(_ bytes: [UInt8]) {
        if bytes.isEmpty {
            return
        }
        bytes.withUnsafeBytes { (base + count).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        count += bytes.count
    }
}
