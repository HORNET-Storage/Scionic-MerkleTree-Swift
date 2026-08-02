// CBOR.swift — Deterministic CBOR encoding/decoding
//
// Produces byte-identical output to Go's fxamacker/cbor v2 (default EncMode) for the same input.
//
// The Go code uses plain CBOR (codec 0x51), NOT DAG-CBOR (0x71).
// All maps are pre-converted to sorted []KeyValue slices before encoding,
// so map key ordering is irrelevant — we only need struct field-order preservation.
//
// fxamacker/cbor default behavior:
//   - Structs → CBOR maps (major type 5) with PascalCase field names as keys
//   - Field order follows Go struct definition order (not sorted)
//   - nil []byte → CBOR null (0xf6)
//   - []byte{} (empty, non-nil) → empty byte string (0x40)
//   - nil []T → CBOR null (0xf6)
//   - []T{} (empty, non-nil) → empty array (0x80)
//   - Integers use shortest encoding (major type 0 for >= 0, type 1 for < 0)

import Foundation

// MARK: - CBOR Errors

/// Errors that can occur during CBOR encoding or decoding.
public enum CBORError: Error, Equatable {
    case prematureEnd
    case invalidCBOR(String)
    case unsupportedType(UInt8)
    case invalidUTF8
    case integerOverflow
}

// MARK: - CBOR Ordered Map

/// An ordered map of CBOR string keys to CBOR values.
/// Preserves insertion order — critical for deterministic encoding matching Go struct field order.
public struct CBOROrderedMap: Equatable {
    public var pairs: [(key: String, value: CBORValue)]

    public init(_ pairs: [(String, CBORValue)] = []) {
        self.pairs = pairs.map { (key: $0.0, value: $0.1) }
    }

    public static func == (lhs: CBOROrderedMap, rhs: CBOROrderedMap) -> Bool {
        guard lhs.pairs.count == rhs.pairs.count else { return false }
        for (l, r) in zip(lhs.pairs, rhs.pairs) {
            if l.key != r.key || l.value != r.value { return false }
        }
        return true
    }

    /// Looks up a value by key.
    public subscript(key: String) -> CBORValue? {
        pairs.first(where: { $0.key == key })?.value
    }
}

// MARK: - CBOR Value

/// Represents a CBOR-encodable value.
///
/// Maps directly to CBOR major types:
///   - `.unsignedInt` → major type 0
///   - `.negativeInt` → major type 1
///   - `.byteString`  → major type 2
///   - `.textString`  → major type 3
///   - `.array`       → major type 4
///   - `.map`         → major type 5
///   - `.null/.bool`  → major type 7 (simple values)
public enum CBORValue: Equatable {
    case unsignedInt(UInt64)
    case negativeInt(Int64)     // The actual negative value (e.g., -1)
    case byteString(Data)
    case textString(String)
    case array([CBORValue])
    case map(CBOROrderedMap)    // Ordered key-value pairs
    case null
    case bool(Bool)
    case undefined
}

// MARK: - Wire Key Order

/// Which comparator a dynamic wire map's keys sort by.
///
/// CBOR and JSON do not agree on map key order, and never did. Both rules are
/// deterministic; they are simply different rules, so the choice belongs to the
/// output format rather than to the wire tree the two formats share:
///
///   - `.cbor` is RFC 8949 core-deterministic ordering -- keys sort by their
///     ENCODED bytes, which for text keys reduces exactly to length-first, then
///     bytewise. See `CBOREncoder.sortedWireMap` for why that reduction is exact.
///   - `.json` is what Go's `encoding/json` does to a map: a plain bytewise
///     compare over the key string, with no length term at all.
///
/// The two agree on every pair of equal-length keys, which is precisely why this
/// divergence went unnoticed for so long. Four of the five dynamic wire maps are
/// keyed by CIDs, which are always exactly 59 characters. `AdditionalData` is the
/// one keyed by arbitrary caller-chosen strings, and it is empty in every spec
/// vector and every benchmark-corpus leaf -- so no map any cross-port check has
/// ever compared held two keys of different lengths.
///
/// The Rust port emitted the CBOR comparator into JSON until this was caught by
/// diffing its bytes against Go. All three ports now carry the distinction.
public enum WireKeyOrder {
    case cbor
    case json
}

// MARK: - Convenience Constructors

extension CBORValue {
    /// Creates from a Swift Int — unsigned if >= 0, negative otherwise.
    public static func int(_ value: Int) -> CBORValue {
        if value >= 0 {
            return .unsignedInt(UInt64(value))
        } else {
            return .negativeInt(Int64(value))
        }
    }

    /// Creates from a Swift Int64 — unsigned if >= 0, negative otherwise.
    public static func int64(_ value: Int64) -> CBORValue {
        if value >= 0 {
            return .unsignedInt(UInt64(value))
        } else {
            return .negativeInt(value)
        }
    }

    /// Creates from optional Data — `.null` if nil, `.byteString` if non-nil.
    public static func optionalBytes(_ value: Data?) -> CBORValue {
        guard let value = value else { return .null }
        return .byteString(value)
    }

    /// Creates from an optional array — `.null` if nil, `.array` if non-nil (including empty).
    public static func optionalArray(_ value: [CBORValue]?) -> CBORValue {
        guard let value = value else { return .null }
        return .array(value)
    }
}

// MARK: - CBOR Major Types (Private)

private enum CBORMajorType: UInt8 {
    case unsignedInt = 0
    case negativeInt = 1
    case byteString  = 2
    case textString  = 3
    case array       = 4
    case map         = 5
    case tag         = 6
    case simple      = 7
}

// MARK: - CBOR Encoder

/// Encodes Swift values to CBOR binary format.
///
/// Matches the output of Go's `fxamacker/cbor` v2 default encoding mode:
/// - Maps preserve insertion order (not sorted)
/// - Integers use shortest form encoding
/// - nil → CBOR null (0xf6)
/// - Empty Data → empty byte string (0x40)
public struct CBOREncoder {

    public init() {}

    /// Encodes a `CBORValue` to its CBOR binary representation.
    public func encode(_ value: CBORValue) -> Data {
        var data = Data()
        encodeValue(value, into: &data)
        return data
    }

    /// Encodes an ordered map (Go struct equivalent) to CBOR.
    ///
    /// This is the primary method for leaf hashing — mirrors `cbor.Marshal(struct{...}{...})`.
    ///
    ///     let data = encoder.encodeMap([
    ///         ("ItemName", .textString("myfile.txt")),
    ///         ("Type", .textString("file")),
    ///         ("MerkleRoot", .byteString(Data())),
    ///         ("CurrentLinkCount", .int(0)),
    ///         ("ContentHash", .null),
    ///         ("AdditionalData", .null),
    ///     ])
    public func encodeMap(_ pairs: [(String, CBORValue)]) -> Data {
        return encode(.map(CBOROrderedMap(pairs)))
    }

    /// Builds a wire map whose keys are ordered by `order`.
    ///
    /// Applied PER MAP, at the few sites that build a genuinely dynamic map --
    /// `Leafs`, `AdditionalData`, `stored_proofs`, `proofs`, `Relationships` --
    /// and NEVER to the struct-shaped maps around them.
    ///
    /// That distinction is invisible in Swift, where a struct and a map are both
    /// `.map(CBOROrderedMap)`, but it is load-bearing on the wire. Go's wire types
    /// are structs with map FIELDS: fxamacker emits struct fields in declaration
    /// order and only randomizes map iteration, so only the maps were ever
    /// unordered. A blanket sort over the encoded tree shipped here briefly and
    /// reordered the struct fields too, which `CrossCompatWireTests` caught against
    /// golden bytes captured from a real deployed v2.2.6 build:
    ///
    ///     expected [Leaves, Relationships, PacketIndex, TotalPackets]  (declaration)
    ///     got      [Leaves, PacketIndex, TotalPackets, Relationships]  (sorted)
    ///
    /// That same five-way scoping is what makes `WireKeyOrder` safe to vary: only
    /// these five maps ever see the JSON comparator, and the struct-shaped maps
    /// around them stay in declaration order for BOTH output formats.
    ///
    /// For `.cbor`, RFC 8949 orders map keys by their ENCODED bytes, bytewise. For
    /// text keys that reduces to length-first, then bytewise on the UTF-8 -- and it
    /// reduces exactly, at every boundary, because the encoded head grows
    /// monotonically with length: a key shorter than 24 bytes starts with
    /// `0x60 + len` (at most `0x77`), one of 24...255 bytes starts with `0x78`, one
    /// of 256...65535 with `0x79`. A shorter key therefore always has a smaller
    /// leading byte, so comparing `(count, bytes)` and comparing encoded forms never
    /// disagree.
    ///
    /// For `.json`, Go's `encoding/json` sorts map keys with a plain bytewise
    /// compare and no length term, so the two orders differ whenever two keys in the
    /// same map differ in length.
    ///
    /// Note neither is the same comparator as `sortMapByKeys` /
    /// `sortMapForVerification`, which order by the decoded string. Those feed the
    /// CID preimage, where AdditionalData is a CBOR *array* of key/value structs --
    /// map-key rules never apply to it, and its order is frozen into every CID ever
    /// minted. Do not unify the three.
    public static func sortedWireMap(
        _ pairs: [(String, CBORValue)],
        order: WireKeyOrder
    ) -> CBORValue {
        let sorted = pairs.sorted { left, right in
            let leftBytes = Array(left.0.utf8)
            let rightBytes = Array(right.0.utf8)
            if order == .cbor && leftBytes.count != rightBytes.count {
                return leftBytes.count < rightBytes.count
            }
            return leftBytes.lexicographicallyPrecedes(rightBytes)
        }
        return .map(CBOROrderedMap(sorted))
    }

    // MARK: - Private Encoding

    private func encodeValue(_ value: CBORValue, into data: inout Data) {
        switch value {
        case .unsignedInt(let v):
            encodeUnsignedInt(v, majorType: .unsignedInt, into: &data)

        case .negativeInt(let v):
            // CBOR negative int encoding: value = -1 - n, so n = -1 - value
            let n = UInt64(bitPattern: -1 - v)
            encodeUnsignedInt(n, majorType: .negativeInt, into: &data)

        case .byteString(let bytes):
            encodeUnsignedInt(UInt64(bytes.count), majorType: .byteString, into: &data)
            data.append(bytes)

        case .textString(let str):
            let utf8 = Data(str.utf8)
            encodeUnsignedInt(UInt64(utf8.count), majorType: .textString, into: &data)
            data.append(utf8)

        case .array(let items):
            encodeUnsignedInt(UInt64(items.count), majorType: .array, into: &data)
            for item in items {
                encodeValue(item, into: &data)
            }

        case .map(let orderedMap):
            encodeUnsignedInt(UInt64(orderedMap.pairs.count), majorType: .map, into: &data)
            for pair in orderedMap.pairs {
                encodeValue(.textString(pair.key), into: &data)
                encodeValue(pair.value, into: &data)
            }

        case .null:
            data.append(0xf6)

        case .bool(let v):
            data.append(v ? 0xf5 : 0xf4)

        case .undefined:
            data.append(0xf7)
        }
    }

    /// Encodes an unsigned integer with the given major type prefix.
    /// Uses shortest form (matching fxamacker/cbor default):
    ///   - 0-23:         1 byte   `[major | value]`
    ///   - 24-255:       2 bytes  `[major | 24, value]`
    ///   - 256-65535:    3 bytes  `[major | 25, value_hi, value_lo]`
    ///   - 65536-2^32-1: 5 bytes  `[major | 26, 4 bytes big-endian]`
    ///   - 2^32-2^64-1:  9 bytes  `[major | 27, 8 bytes big-endian]`
    private func encodeUnsignedInt(_ value: UInt64, majorType: CBORMajorType, into data: inout Data) {
        let major = majorType.rawValue << 5

        if value < 24 {
            data.append(major | UInt8(value))
        } else if value <= UInt8.max {
            data.append(major | 24)
            data.append(UInt8(value))
        } else if value <= UInt16.max {
            data.append(major | 25)
            appendBigEndian(UInt16(value), into: &data)
        } else if value <= UInt32.max {
            data.append(major | 26)
            appendBigEndian(UInt32(value), into: &data)
        } else {
            data.append(major | 27)
            appendBigEndian(value, into: &data)
        }
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

// MARK: - CBOR Decoder

/// Decodes CBOR binary data into `CBORValue`.
///
/// Handles all types produced by `fxamacker/cbor` default encoding.
public struct CBORDecoder {

    public init() {}

    /// Decodes CBOR binary data into a `CBORValue`.
    public func decode(_ data: Data) throws -> CBORValue {
        var offset = data.startIndex
        return try decodeValue(data, offset: &offset)
    }

    // MARK: - Private Decoding

    private func decodeValue(_ data: Data, offset: inout Data.Index) throws -> CBORValue {
        guard offset < data.endIndex else {
            throw CBORError.prematureEnd
        }

        let initialByte = data[offset]
        let majorType = initialByte >> 5
        let additionalInfo = initialByte & 0x1f
        offset += 1

        switch majorType {
        case 0: // Unsigned integer
            let value = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            return .unsignedInt(value)

        case 1: // Negative integer
            let n = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            guard n <= UInt64(Int64.max) else { throw CBORError.integerOverflow }
            return .negativeInt(-1 - Int64(n))

        case 2: // Byte string
            let length = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            let len = Int(length)
            guard offset + len <= data.endIndex else { throw CBORError.prematureEnd }
            let bytes = data[offset..<(offset + len)]
            offset += len
            return .byteString(Data(bytes))

        case 3: // Text string
            let length = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            let len = Int(length)
            guard offset + len <= data.endIndex else { throw CBORError.prematureEnd }
            let bytes = data[offset..<(offset + len)]
            offset += len
            guard let str = String(data: Data(bytes), encoding: .utf8) else {
                throw CBORError.invalidUTF8
            }
            return .textString(str)

        case 4: // Array
            let count = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            var items: [CBORValue] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count {
                items.append(try decodeValue(data, offset: &offset))
            }
            return .array(items)

        case 5: // Map
            let count = try decodeLength(data, additionalInfo: additionalInfo, offset: &offset)
            var pairs: [(String, CBORValue)] = []
            pairs.reserveCapacity(Int(count))
            for _ in 0..<count {
                let key = try decodeValue(data, offset: &offset)
                guard case .textString(let keyStr) = key else {
                    throw CBORError.invalidCBOR("map key must be a text string")
                }
                let value = try decodeValue(data, offset: &offset)
                pairs.append((keyStr, value))
            }
            return .map(CBOROrderedMap(pairs))

        case 7: // Simple values and floats
            switch additionalInfo {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            default:
                throw CBORError.unsupportedType(initialByte)
            }

        default:
            throw CBORError.unsupportedType(initialByte)
        }
    }

    /// Decodes the length/value component of a CBOR item.
    private func decodeLength(_ data: Data, additionalInfo: UInt8, offset: inout Data.Index) throws -> UInt64 {
        if additionalInfo < 24 {
            return UInt64(additionalInfo)
        } else if additionalInfo == 24 {
            guard offset < data.endIndex else { throw CBORError.prematureEnd }
            let value = UInt64(data[offset])
            offset += 1
            return value
        } else if additionalInfo == 25 {
            guard offset + 2 <= data.endIndex else { throw CBORError.prematureEnd }
            let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2
            return UInt64(value)
        } else if additionalInfo == 26 {
            guard offset + 4 <= data.endIndex else { throw CBORError.prematureEnd }
            let value = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
                        UInt32(data[offset + 2]) << 8  | UInt32(data[offset + 3])
            offset += 4
            return UInt64(value)
        } else if additionalInfo == 27 {
            guard offset + 8 <= data.endIndex else { throw CBORError.prematureEnd }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[offset + i])
            }
            offset += 8
            return value
        } else {
            throw CBORError.invalidCBOR("invalid additional info for integer: \(additionalInfo)")
        }
    }
}

// MARK: - CBORValue Extraction Helpers

extension CBORValue {
    /// Extracts the string value, or nil if not a text string.
    public var stringValue: String? {
        if case .textString(let s) = self { return s }
        return nil
    }

    /// Extracts the unsigned integer value, or nil.
    public var uintValue: UInt64? {
        if case .unsignedInt(let v) = self { return v }
        return nil
    }

    /// Extracts as a Swift Int, handling both unsigned and negative.
    public var intValue: Int? {
        switch self {
        case .unsignedInt(let v):
            return v <= UInt64(Int.max) ? Int(v) : nil
        case .negativeInt(let v):
            return Int(exactly: v)
        default:
            return nil
        }
    }

    /// Extracts as Int64, handling both unsigned and negative.
    public var int64Value: Int64? {
        switch self {
        case .unsignedInt(let v):
            return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .negativeInt(let v):
            return v
        default:
            return nil
        }
    }

    /// Extracts the byte string value, or nil.
    public var dataValue: Data? {
        if case .byteString(let d) = self { return d }
        return nil
    }

    /// Extracts the array value, or nil.
    public var arrayValue: [CBORValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Extracts the ordered map, or nil.
    public var mapValue: CBOROrderedMap? {
        if case .map(let m) = self { return m }
        return nil
    }

    /// Returns true if this value is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
