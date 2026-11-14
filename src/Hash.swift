/// A SHA-256 hash: of a chunk's bytes, or of the bytes that describe a file,
/// a folder or a tree.
///
/// Hashes compare as their bytes do.
public struct Hash: Hashable, Comparable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    // The 32 bytes as four numbers, each read big-endian from 8 of them, so
    // that comparing the numbers in order compares the bytes.
    @usableFromInline let w0: UInt64
    @usableFromInline let w1: UInt64
    @usableFromInline let w2: UInt64
    @usableFromInline let w3: UInt64

    @usableFromInline init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// What an empty list has in place of a hash.
    public static let zero = Hash(w0: 0, w1: 0, w2: 0, w3: 0)

    /// Reads a hash from 32 bytes. The caller has checked the count.
    @inline(__always)
    init(rawBytes raw: UnsafeRawBufferPointer) {
        precondition(raw.count == 32, "a hash is 32 bytes")
        w0 = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
        w1 = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        w2 = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        w3 = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
    }

    /// Reads a hash from exactly 32 bytes.
    public init<Bytes: Collection>(bytes: Bytes) throws where Bytes.Element == UInt8 {
        guard bytes.count == 32 else {
            throw invalid("a hash is not 32 bytes")
        }
        self = Array(bytes).withUnsafeBytes { Hash(rawBytes: $0) }
    }

    /// The SHA-256 of `bytes`.
    public static func of(_ bytes: [UInt8]) -> Hash {
        sha256(bytes)
    }

    /// The SHA-256 of `bytes`.
    public static func of(_ bytes: ArraySlice<UInt8>) -> Hash {
        sha256(bytes)
    }

    /// The SHA-256 of `bytes`.
    public static func of(_ bytes: UnsafeRawBufferPointer) -> Hash {
        sha256(bytes)
    }

    /// Lends the hash's 32 bytes for the length of `body`.
    @inline(__always)
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        var words = (w0.bigEndian, w1.bigEndian, w2.bigEndian, w3.bigEndian)
        return try Swift.withUnsafeBytes(of: &words) { try body($0) }
    }

    /// The hash's 32 bytes.
    public var bytes: [UInt8] {
        withUnsafeBytes { Array($0) }
    }

    /// The hash as 64 lowercase hex digits.
    public var hex: String {
        withUnsafeBytes { hexLower($0) }
    }

    /// Reads 64 lowercase hex digits.
    public init(hex text: String) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        try hexLowerDecode(text, into: &bytes)
        self = bytes.withUnsafeBytes { Hash(rawBytes: $0) }
    }

    public static func < (a: Hash, b: Hash) -> Bool {
        (a.w0, a.w1, a.w2, a.w3) < (b.w0, b.w1, b.w2, b.w3)
    }

    public var description: String { hex }
    public var debugDescription: String { "Hash(\(hex))" }
}

/// What a root's text form starts with, before the hash: CID version 1, raw
/// content, SHA-256, 32 bytes.
private let rootPrefix: [UInt8] = [0x01, 0x55, 0x12, 0x20]

/// The root of a tree: the hash of its record. It is what a tree is known by.
///
/// Written out, a root is a CID that begins `bafkrei`.
public struct Root: Hashable, Comparable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let hash: Hash

    public init(hash: Hash) {
        self.hash = hash
    }

    /// The root of the tree whose record is `record`.
    public static func of(record: [UInt8]) -> Root {
        Root(hash: sha256(record))
    }

    /// The root as text.
    public var text: String {
        var bytes = rootPrefix
        bytes.reserveCapacity(36)
        bytes.append(hash)
        return "b" + base32Lower(bytes)
    }

    /// Reads a root from its text. Only the one way of writing a root is read:
    /// any other spelling of the same bytes is refused.
    public init(text: String) throws {
        let wrong = ScionicError.invalidRoot(text)
        guard text.utf8.first == UInt8(ascii: "b") else {
            throw wrong
        }
        guard let bytes = try? base32LowerDecode(text.utf8.dropFirst()),
              bytes.count == 36, Array(bytes[..<4]) == rootPrefix else {
            throw wrong
        }
        let root = Root(hash: try Hash(bytes: bytes[4...]))
        guard root.text == text else {
            throw wrong
        }
        self = root
    }

    public static func < (a: Root, b: Root) -> Bool {
        a.hash < b.hash
    }

    public var description: String { text }
    public var debugDescription: String { "Root(\(text))" }
}

// MARK: - Text

private let base32Alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
private let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

/// Lowercase base32 with no padding.
func base32Lower(_ input: [UInt8]) -> String {
    var output: [UInt8] = []
    output.reserveCapacity((input.count * 8 + 4) / 5)
    var accumulator: UInt32 = 0
    var bits: UInt32 = 0
    for byte in input {
        accumulator = (accumulator << 8) | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            output.append(base32Alphabet[Int((accumulator >> bits) & 0x1f)])
        }
    }
    if bits != 0 {
        output.append(base32Alphabet[Int((accumulator << (5 - bits)) & 0x1f)])
    }
    return String(decoding: output, as: UTF8.self)
}

/// Reads lowercase base32 with no padding. A letter outside the alphabet is an
/// error, and so are bits left over that are not zero.
func base32LowerDecode<Letters: Sequence>(_ input: Letters) throws -> [UInt8] where Letters.Element == UInt8 {
    var output: [UInt8] = []
    var accumulator: UInt32 = 0
    var bits: UInt32 = 0
    for byte in input {
        let value: UInt8
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            value = byte - UInt8(ascii: "a")
        case UInt8(ascii: "2")...UInt8(ascii: "7"):
            value = byte - UInt8(ascii: "2") + 26
        default:
            throw ScionicError.invalidBase32
        }
        accumulator = (accumulator << 5) | UInt32(value)
        bits += 5
        if bits >= 8 {
            bits -= 8
            output.append(UInt8(truncatingIfNeeded: accumulator >> bits))
            accumulator &= bits == 0 ? 0 : (UInt32(1) << bits) - 1
        }
    }
    if bits != 0 && accumulator != 0 {
        throw ScionicError.invalidBase32
    }
    return output
}

func hexLower(_ input: UnsafeRawBufferPointer) -> String {
    var output: [UInt8] = []
    output.reserveCapacity(input.count * 2)
    for byte in input {
        output.append(hexAlphabet[Int(byte >> 4)])
        output.append(hexAlphabet[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
}

func hexLower(_ input: [UInt8]) -> String {
    input.withUnsafeBytes { hexLower($0) }
}

/// Reads lowercase hex into `output`, which it must fill exactly.
func hexLowerDecode(_ input: String, into output: inout [UInt8]) throws {
    let digits = Array(input.utf8)
    guard digits.count == output.count * 2 else {
        throw ScionicError.invalidHex
    }
    for slot in 0..<output.count {
        output[slot] = try hexValue(digits[slot * 2]) << 4 | hexValue(digits[slot * 2 + 1])
    }
}

private func hexValue(_ byte: UInt8) throws -> UInt8 {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return byte - UInt8(ascii: "a") + 10
    default:
        throw ScionicError.invalidHex
    }
}
