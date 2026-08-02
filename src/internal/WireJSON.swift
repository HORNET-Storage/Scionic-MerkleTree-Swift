// WireJSON.swift — Go-compatible JSON writer over the shared wire tree
//
// This port reaches JSON the same way the Rust port does, and for the same
// reason: ONE wire tree (`CBORValue`) is built, and either writer consumes it.
// That is what makes key names and struct field order structurally unable to
// drift between the two formats -- they are literally reading the same tree.
//
// The alternative, which this replaced, was Foundation's `JSONEncoder` over the
// `Codable` conformances. Foundation cannot produce Go's output at all: it has
// no way to emit struct fields in declaration order (only `.sortedKeys`), it
// writes `"k" : v` rather than `"k": v`, it expands empty containers across
// three lines, it omits nil keys where Go writes `null`, and it escapes the
// solidus. Every one of those is a byte difference on every leaf.
//
// The reference is Go's `json.MarshalIndent(v, "", "  ")`, mirrored in Rust at
// src/serialization.rs :: write_json / write_indent / write_json_string.

import Foundation

/// Serializes a wire tree to JSON bytes identical to Go's
/// `json.MarshalIndent(v, "", "  ")`.
public func encodeWireJSON(_ value: CBORValue) throws -> Data {
    var output: [UInt8] = []
    output.reserveCapacity(4096)
    try writeWireJSON(value, into: &output, depth: 0)
    return Data(output)
}

/// Appends `value` to `output` as Go-compatible JSON.
///
/// Indentation is two spaces per level. Empty containers are compact (`[]`, `{}`);
/// non-empty ones open, then emit newline + indent(depth+1) + item per element with
/// commas BETWEEN items only, then newline + indent(depth) + close. Map pairs are
/// separated by exactly `": "`. Byte strings become standard base64 inside a JSON
/// string, matching Go marshalling a `[]byte`.
func writeWireJSON(_ value: CBORValue, into output: inout [UInt8], depth: Int) throws {
    switch value {
    case .unsignedInt(let number):
        appendASCII(String(number), into: &output)

    case .negativeInt:
        // No wire field is signed. Go's types are uint64/int64-with-nonnegative-
        // values, so a negative here means the tree was built wrong, not that JSON
        // needs a representation for it.
        throw DagError.brokenDag("wire JSON cannot contain negative integers")

    case .undefined:
        throw DagError.brokenDag("wire JSON cannot contain undefined")

    case .byteString(let bytes):
        writeWireJSONString(bytes.base64EncodedString(), into: &output)

    case .textString(let text):
        writeWireJSONString(text, into: &output)

    case .array(let values):
        if values.isEmpty {
            appendLiteral("[]", into: &output)
        } else {
            output.append(UInt8(ascii: "["))
            for (index, element) in values.enumerated() {
                output.append(UInt8(ascii: "\n"))
                writeWireJSONIndent(depth + 1, into: &output)
                try writeWireJSON(element, into: &output, depth: depth + 1)
                if index + 1 != values.count {
                    output.append(UInt8(ascii: ","))
                }
            }
            output.append(UInt8(ascii: "\n"))
            writeWireJSONIndent(depth, into: &output)
            output.append(UInt8(ascii: "]"))
        }

    case .map(let orderedMap):
        let pairs = orderedMap.pairs
        if pairs.isEmpty {
            appendLiteral("{}", into: &output)
        } else {
            output.append(UInt8(ascii: "{"))
            for (index, pair) in pairs.enumerated() {
                output.append(UInt8(ascii: "\n"))
                writeWireJSONIndent(depth + 1, into: &output)
                writeWireJSONString(pair.key, into: &output)
                output.append(UInt8(ascii: ":"))
                output.append(UInt8(ascii: " "))
                try writeWireJSON(pair.value, into: &output, depth: depth + 1)
                if index + 1 != pairs.count {
                    output.append(UInt8(ascii: ","))
                }
            }
            output.append(UInt8(ascii: "\n"))
            writeWireJSONIndent(depth, into: &output)
            output.append(UInt8(ascii: "}"))
        }

    case .null:
        appendLiteral("null", into: &output)

    case .bool(let flag):
        appendLiteral(flag ? "true" : "false", into: &output)
    }
}

func writeWireJSONIndent(_ depth: Int, into output: inout [UInt8]) {
    for _ in 0..<depth {
        output.append(UInt8(ascii: " "))
        output.append(UInt8(ascii: " "))
    }
}

/// Writes a JSON string literal using Go's `encoding/json` escaping rules.
///
/// Two of these are surprising and both are deliberate:
///
///   - `<`, `>` and `&` are escaped to `<`, `>`, `&`. Go's encoder
///     does this by default (SetEscapeHTML defaults to true) so marshalled output
///     is safe to embed in HTML. It is not optional here: the reference does it.
///   - The solidus `/` is NOT escaped. Base64 uses `/` heavily, so this is the
///     single highest-volume difference against Foundation, which escapes it.
///
/// Iteration is over unicode scalars rather than Characters. A Character is a
/// grapheme cluster, so a combining sequence would be one Character but several
/// scalars, and escaping decisions have to be made per scalar to match Go and Rust.
func writeWireJSONString(_ value: String, into output: inout [UInt8]) {
    output.append(UInt8(ascii: "\""))
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": appendLiteral("\\\"", into: &output)
        case "\\": appendLiteral("\\\\", into: &output)
        case "\u{08}": appendLiteral("\\b", into: &output)
        case "\u{0c}": appendLiteral("\\f", into: &output)
        case "\n": appendLiteral("\\n", into: &output)
        case "\r": appendLiteral("\\r", into: &output)
        case "\t": appendLiteral("\\t", into: &output)
        case "<": appendLiteral("\\u003c", into: &output)
        case ">": appendLiteral("\\u003e", into: &output)
        case "&": appendLiteral("\\u0026", into: &output)
        case "\u{2028}": appendLiteral("\\u2028", into: &output)
        case "\u{2029}": appendLiteral("\\u2029", into: &output)
        default:
            if scalar.value <= 0x1f {
                // Rust writes format!("\\u{:04x}"). Every value reaching here is
                // <= 0x1f, so the high byte is always "00" and the low two digits
                // are lowercase hex -- identical output, no formatter needed.
                appendLiteral("\\u00", into: &output)
                output.append(lowercaseHexDigits[Int((scalar.value >> 4) & 0xf)])
                output.append(lowercaseHexDigits[Int(scalar.value & 0xf)])
            } else {
                UTF8.encode(scalar) { output.append($0) }
            }
        }
    }
    output.append(UInt8(ascii: "\""))
}

private let lowercaseHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Appends a compile-time literal without allocating: a StaticString exposes its
/// UTF-8 storage directly.
private func appendLiteral(_ text: StaticString, into output: inout [UInt8]) {
    if text.hasPointerRepresentation {
        output.append(
            contentsOf: UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
        )
    } else {
        appendASCII(text.description, into: &output)
    }
}

private func appendASCII(_ text: String, into output: inout [UInt8]) {
    output.append(contentsOf: text.utf8)
}
