// Varint.swift — Unsigned variable-length integer encoding (LEB128)
//
// Used in CID and multihash binary format.
// Each byte uses 7 data bits + 1 continuation bit (MSB).
// For values < 128, the varint is just the byte itself.

import Foundation

// MARK: - Unsigned Varint (LEB128)

/// Encodes and decodes unsigned variable-length integers.
///
/// Format: each byte has 7 data bits (LSB first) and 1 continuation bit (MSB).
/// - If MSB = 1, more bytes follow.
/// - If MSB = 0, this is the last byte.
///
/// Examples:
///   - 0x01 (1)    → [0x01]
///   - 0x12 (18)   → [0x12]  (SHA2-256 hash code)
///   - 0x20 (32)   → [0x20]  (SHA2-256 digest length)
///   - 0x51 (81)   → [0x51]  (CBOR codec)
///   - 0x71 (113)  → [0x71]  (DAG-CBOR codec)
///   - 0x80 (128)  → [0x80, 0x01]
///   - 0x0200 (512)→ [0x80, 0x04]
public enum Varint {

    /// Encodes a UInt64 as an unsigned varint (LEB128).
    public static func encode(_ value: UInt64) -> Data {
        var data = Data()
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
        return data
    }

    /// Decodes an unsigned varint from the data at the given offset.
    /// Returns the decoded value and the number of bytes consumed.
    public static func decode(_ data: Data, offset: Int = 0) throws -> (value: UInt64, bytesRead: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset

        while i < data.count {
            let byte = data[i]
            value |= UInt64(byte & 0x7f) << shift
            i += 1

            if byte & 0x80 == 0 {
                return (value, i - offset)
            }

            shift += 7
            if shift >= 64 {
                throw CIDError.varintOverflow
            }
        }

        throw CIDError.truncatedVarint
    }
}
