// WireJSONParser.swift — hand-written JSON reader for the wire types
//
// This replaces Foundation's JSONDecoder on the wire path. Two layers, mirroring
// the Rust port:
//
//   1. A byte-driven parser producing a generic `WireJSONValue`.
//   2. A SCHEMA-DIRECTED walk turning that into the same `CBORValue` tree the CBOR
//      decoder already consumes.
//
// Layer 2 is not optional plumbing, it is the whole point. JSON carries Content,
// ContentHash, ClassicMerkleRoot and Proof.Siblings as base64 TEXT, while CBOR
// carries them as raw byte strings. A naive JSON->CBORValue conversion would hand
// the existing `cborToSerializable*` decoders `.textString` where they expect
// `.byteString`. Walking by schema converts exactly the fields that need it, which
// is what lets BOTH formats share one decode schema instead of maintaining two.
//
// Key lookup accepts the canonical PascalCase spelling and the camelCase alias, so
// documents written by older builds of this port still read. Output always uses the
// canonical spelling.

import Foundation

// MARK: - Generic JSON value

public enum WireJSONValue {
    case null
    case bool(Bool)
    case number(UInt64)
    case string(String)
    case array([WireJSONValue])
    case object([(key: String, value: WireJSONValue)])
}

/// Parses JSON bytes into a generic tree.
public func parseWireJSON(_ data: Data) throws -> WireJSONValue {
    var parser = WireJSONParser(Array(data))
    return try parser.parseDocument()
}

struct WireJSONParser {
    private let input: [UInt8]
    private var position: Int

    /// No wire document nests anywhere near this deep -- a DAG bottoms out around
    /// eight levels (dag > Leafs > leaf > stored_proofs > branch > Proof > Siblings
    /// > entry). The limit exists so hostile input cannot exhaust the stack through
    /// the recursive descent, since this parses data that arrives over the network.
    private static let maxDepth = 128

    init(_ input: [UInt8]) {
        self.input = input
        self.position = 0
    }

    mutating func parseDocument() throws -> WireJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard position == input.count else {
            throw DagError.brokenDag("trailing data after JSON document")
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> WireJSONValue {
        guard depth <= Self.maxDepth else {
            throw DagError.brokenDag("JSON nesting is too deep")
        }
        guard position < input.count else {
            throw DagError.brokenDag("unexpected end of JSON input")
        }
        switch input[position] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) throws -> WireJSONValue {
        position += 1  // '{'
        var pairs: [(key: String, value: WireJSONValue)] = []
        skipWhitespace()
        if position < input.count, input[position] == UInt8(ascii: "}") {
            position += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard position < input.count, input[position] == UInt8(ascii: "\"") else {
                throw DagError.brokenDag("expected a JSON object key")
            }
            let key = try parseString()
            skipWhitespace()
            guard position < input.count, input[position] == UInt8(ascii: ":") else {
                throw DagError.brokenDag("expected ':' after JSON object key")
            }
            position += 1
            skipWhitespace()
            pairs.append((key: key, value: try parseValue(depth: depth + 1)))
            skipWhitespace()
            guard position < input.count else {
                throw DagError.brokenDag("unterminated JSON object")
            }
            if input[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }
            if input[position] == UInt8(ascii: "}") {
                position += 1
                return .object(pairs)
            }
            throw DagError.brokenDag("expected ',' or '}' in JSON object")
        }
    }

    private mutating func parseArray(depth: Int) throws -> WireJSONValue {
        position += 1  // '['
        var values: [WireJSONValue] = []
        skipWhitespace()
        if position < input.count, input[position] == UInt8(ascii: "]") {
            position += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard position < input.count else {
                throw DagError.brokenDag("unterminated JSON array")
            }
            if input[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }
            if input[position] == UInt8(ascii: "]") {
                position += 1
                return .array(values)
            }
            throw DagError.brokenDag("expected ',' or ']' in JSON array")
        }
    }

    /// Parses an unsigned integer.
    ///
    /// Every numeric wire field is a count or a size, so fractions, exponents and
    /// negatives are all rejected rather than silently coerced. The Rust port's
    /// JSON number type is likewise `u64`.
    private mutating func parseNumber() throws -> WireJSONValue {
        if input[position] == UInt8(ascii: "-") {
            throw DagError.brokenDag("wire JSON cannot contain negative numbers")
        }
        var value: UInt64 = 0
        var digits = 0
        while position < input.count,
              input[position] >= UInt8(ascii: "0"),
              input[position] <= UInt8(ascii: "9") {
            let digit = UInt64(input[position] - UInt8(ascii: "0"))
            let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
            guard !scaleOverflow else {
                throw DagError.brokenDag("JSON number overflows a 64-bit unsigned integer")
            }
            let (summed, sumOverflow) = scaled.addingReportingOverflow(digit)
            guard !sumOverflow else {
                throw DagError.brokenDag("JSON number overflows a 64-bit unsigned integer")
            }
            value = summed
            digits += 1
            position += 1
        }
        guard digits > 0 else {
            throw DagError.brokenDag("invalid JSON value")
        }
        if position < input.count {
            let next = input[position]
            if next == UInt8(ascii: ".") || next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
                throw DagError.brokenDag("wire JSON numbers must be unsigned integers")
            }
        }
        return .number(value)
    }

    private mutating func parseString() throws -> String {
        position += 1  // opening quote
        var bytes: [UInt8] = []
        while true {
            guard position < input.count else {
                throw DagError.brokenDag("unterminated JSON string")
            }
            let byte = input[position]
            if byte == UInt8(ascii: "\"") {
                position += 1
                guard let text = String(bytes: bytes, encoding: .utf8) else {
                    throw DagError.brokenDag("JSON string is not valid UTF-8")
                }
                return text
            }
            if byte == UInt8(ascii: "\\") {
                position += 1
                guard position < input.count else {
                    throw DagError.brokenDag("unterminated JSON escape")
                }
                let escape = input[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): bytes.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0c)
                case UInt8(ascii: "n"): bytes.append(0x0a)
                case UInt8(ascii: "r"): bytes.append(0x0d)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "u"):
                    UTF8.encode(try parseUnicodeEscape()) { bytes.append($0) }
                default:
                    throw DagError.brokenDag("unknown escape in JSON string")
                }
                continue
            }
            bytes.append(byte)
            position += 1
        }
    }

    /// Reads the four hex digits after `\u`, joining a surrogate pair when one is
    /// present. Go escapes U+2028 and U+2029 unconditionally, so this path is
    /// exercised by ordinary reference output, not only by exotic input.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try readHex4()
        if first >= 0xd800 && first <= 0xdbff {
            guard position + 1 < input.count,
                  input[position] == UInt8(ascii: "\\"),
                  input[position + 1] == UInt8(ascii: "u") else {
                throw DagError.brokenDag("unpaired high surrogate in JSON string")
            }
            position += 2
            let second = try readHex4()
            guard second >= 0xdc00 && second <= 0xdfff else {
                throw DagError.brokenDag("invalid low surrogate in JSON string")
            }
            let combined = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw DagError.brokenDag("invalid surrogate pair in JSON string")
            }
            return scalar
        }
        guard let scalar = Unicode.Scalar(first) else {
            throw DagError.brokenDag("invalid unicode escape in JSON string")
        }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        guard position + 4 <= input.count else {
            throw DagError.brokenDag("truncated unicode escape in JSON string")
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit = input[position]
            position += 1
            let nibble: UInt32
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                nibble = UInt32(digit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                nibble = UInt32(digit - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                nibble = UInt32(digit - UInt8(ascii: "A")) + 10
            default:
                throw DagError.brokenDag("invalid hex digit in unicode escape")
            }
            value = (value << 4) | nibble
        }
        return value
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard position + expected.count <= input.count,
              Array(input[position..<(position + expected.count)]) == expected else {
            throw DagError.brokenDag("invalid JSON literal")
        }
        position += expected.count
    }

    private mutating func skipWhitespace() {
        while position < input.count {
            switch input[position] {
            case 0x20, 0x09, 0x0a, 0x0d: position += 1
            default: return
            }
        }
    }
}
