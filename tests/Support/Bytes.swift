@testable import ScionicMerkleTree

/// The bytes of `text`.
func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

func u64be(_ value: UInt64) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

func u32be(_ value: UInt32) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

func u16be(_ value: UInt16) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

/// `index` with zeros in front, to `width` digits.
func padded(_ index: Int, _ width: Int) -> String {
    let digits = String(index)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

/// The deterministic bytes shared with the conformance vectors: block `k` of
/// the stream is `SHA-256(seed + u64be(k))`; blocks are joined and cut to
/// `length`.
func corpusBytes(_ seed: String, _ length: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(length + 32)
    var block: UInt64 = 0
    let prefix = bytes(seed)
    while out.count < length {
        out.append(contentsOf: Hash.of(prefix + u64be(block)).bytes)
        block += 1
    }
    out.removeLast(out.count - length)
    return out
}

/// A small generator of numbers that repeats from run to run.
struct Numbers {
    var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    mutating func next(_ below: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(below))
    }
}
