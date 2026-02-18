// BaseEncoding.swift — Base58btc and Base32lower encoding/decoding
//
// Used for CID string representation (multibase).
// Zero external dependencies — pure Swift implementations.
//
// Base58btc: Bitcoin-style base58 (alphabet: 123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz)
// Base32lower: RFC 4648 base32, lowercase (alphabet: abcdefghijklmnopqrstuvwxyz234567), no padding

import Foundation

// MARK: - Base32 Lower (RFC 4648, no padding)

/// RFC 4648 Base32 encoding with lowercase alphabet and no padding.
///
/// Alphabet: `abcdefghijklmnopqrstuvwxyz234567`
///
/// This is the default encoding used by go-cid for CIDv1 strings (multibase prefix 'b').
public enum Base32Lower {

    private static let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz234567")

    private static let decodeTable: [UInt8: UInt8] = {
        var table = [UInt8: UInt8]()
        for (i, c) in "abcdefghijklmnopqrstuvwxyz234567".utf8.enumerated() {
            table[c] = UInt8(i)
        }
        return table
    }()

    /// Encodes data to base32lower string (no padding).
    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1f)
                result.append(alphabet[index])
            }
        }

        // Handle remaining bits (< 5)
        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1f)
            result.append(alphabet[index])
        }

        return result
    }

    /// Decodes a base32lower string back to data (ignores padding).
    public static func decode(_ string: String) throws -> Data {
        guard !string.isEmpty else { return Data() }

        var result = Data()
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for char in string.utf8 {
            // Skip padding
            if char == UInt8(ascii: "=") { continue }

            guard let value = decodeTable[char] else {
                throw CIDError.invalidBase32Character
            }

            buffer = (buffer << 5) | UInt64(value)
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                result.append(UInt8((buffer >> bitsLeft) & 0xff))
            }
        }

        return result
    }
}

// MARK: - Base58 BTC (Bitcoin)

/// Bitcoin-style Base58 encoding.
///
/// Alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`
/// (no 0, O, I, l to avoid visual ambiguity)
///
/// Used by go-cid for CIDv0 strings and multibase prefix 'z'.
public enum Base58BTC {

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static let decodeTable: [UInt8: UInt8] = {
        var table = [UInt8: UInt8]()
        for (i, c) in "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8.enumerated() {
            table[c] = UInt8(i)
        }
        return table
    }()

    /// Encodes data to base58btc string.
    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // Count leading zeros
        var leadingZeros = 0
        for byte in data {
            if byte == 0 { leadingZeros += 1 }
            else { break }
        }

        // Convert to base58 using big-number arithmetic on byte array
        var digits: [UInt8] = [0]

        for byte in data {
            var carry = Int(byte)
            for j in 0..<digits.count {
                carry += Int(digits[j]) * 256
                digits[j] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        // Strip trailing zeros from digits (they become leading zeros when reversed)
        // These are already represented by the leadingZeros '1' prefix
        while digits.count > 1 && digits.last == 0 {
            digits.removeLast()
        }

        // Build result: leading '1's for zero bytes, then digits in reverse
        var result = String(repeating: "1", count: leadingZeros)

        // If only a single zero digit remains and all input was zero bytes,
        // skip it — the leading '1's already represent those zeros
        if !(digits.count == 1 && digits[0] == 0 && leadingZeros > 0) {
            for digit in digits.reversed() {
                result.append(alphabet[Int(digit)])
            }
        }

        return result
    }

    /// Decodes a base58btc string back to data.
    public static func decode(_ string: String) throws -> Data {
        guard !string.isEmpty else { return Data() }

        // Count leading '1's (representing zero bytes)
        var leadingOnes = 0
        for char in string {
            if char == "1" { leadingOnes += 1 }
            else { break }
        }

        // Convert from base58 to bytes using big-number arithmetic
        var bytes: [UInt8] = [0]

        for char in string.utf8 {
            guard let value = decodeTable[char] else {
                throw CIDError.invalidBase58Character
            }

            var carry = Int(value)
            for j in 0..<bytes.count {
                carry += Int(bytes[j]) * 58
                bytes[j] = UInt8(carry % 256)
                carry /= 256
            }
            while carry > 0 {
                bytes.append(UInt8(carry % 256))
                carry /= 256
            }
        }

        // Strip trailing zeros from bytes (they become leading zeros when reversed)
        // These are already represented by the leadingOnes 0x00 prefix
        while bytes.count > 1 && bytes.last == 0 {
            bytes.removeLast()
        }

        // Build result: leading zero bytes + number bytes in reverse
        var result = Data(repeating: 0, count: leadingOnes)

        // If only a single zero byte remains and all input was '1's,
        // skip it — the leading 0x00 bytes already represent those
        if !(bytes.count == 1 && bytes[0] == 0 && leadingOnes > 0) {
            for byte in bytes.reversed() {
                result.append(byte)
            }
        }

        return result
    }
}
