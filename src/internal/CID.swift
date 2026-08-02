// CID.swift — Content Identifier generation and parsing
//
// Implements CIDv1 with CBOR codec (0x51) and SHA2-256 multihash (0x12).
//
// Binary format:
//   [0x01]              — CID version 1
//   [varint(0x51)]      — CBOR codec
//   [0x12, 0x20, ...]   — SHA2-256 multihash (0x12 = hash code, 0x20 = 32 bytes, then digest)
//
// String format: multibase-encoded
//   - go-cid default for CIDv1: 'b' prefix + base32lower (no padding)
//   - Also supports: 'z' prefix + base58btc

import Foundation

// MARK: - Constants

/// Well-known multicodec identifiers used by Scionic Merkle Trees.
public enum Multicodec {
    /// Plain CBOR codec (0x51) — used by Scionic Merkle Trees.
    /// NOT DAG-CBOR (0x71) which has different deterministic encoding rules.
    public static let cbor: UInt64 = 0x51

    /// DAG-CBOR codec (0x71) — not used by this library, listed for reference.
    public static let dagCBOR: UInt64 = 0x71
}

/// Well-known multihash function codes.
public enum MultihashCode {
    /// SHA2-256 hash function (0x12), producing 32-byte digests.
    public static let sha2_256: UInt64 = 0x12

    /// SHA2-256 digest length in bytes.
    public static let sha2_256DigestLength: Int = 32
}

// MARK: - CID Errors

public enum CIDError: Error, Equatable {
    case invalidCIDVersion(UInt64)
    case unsupportedCodec(UInt64)
    case unsupportedHashFunction(UInt64)
    case invalidDigestLength(expected: Int, actual: Int)
    case invalidMultibasePrefix(Character)
    case invalidBase32Character
    case invalidBase58Character
    case truncatedCID
    case truncatedVarint
    case varintOverflow
    case invalidCIDString
}

// MARK: - CID

/// A Content Identifier (CIDv1) as used by Scionic Merkle Trees.
///
/// Binary: `[version=1][codec=0x51][multihash]`
/// where multihash = `[hashCode=0x12][digestLength=0x20][32-byte SHA256 digest]`
///
/// String: `b` + base32lower(binary) (go-cid default for CIDv1)
public struct CID: Equatable, Hashable {
    /// CID version (always 1).
    public let version: UInt64
    /// Multicodec code (0x51 for CBOR).
    public let codec: UInt64
    /// Multihash function code (0x12 for SHA2-256).
    public let hashFunction: UInt64
    /// Raw hash digest (32 bytes for SHA256).
    public let digest: Data

    /// Creates a CID from its components.
    public init(version: UInt64 = 1, codec: UInt64 = Multicodec.cbor,
                hashFunction: UInt64 = MultihashCode.sha2_256, digest: Data) {
        self.version = version
        self.codec = codec
        self.hashFunction = hashFunction
        self.digest = digest
    }

    // MARK: - Generation

    /// Creates a CIDv1 by hashing the given data with SHA-256.
    ///
    /// This mirrors Go's `cid.Prefix{Version: 1, Codec: mc.Cbor, MhType: mh.SHA2_256}.Sum(data)`.
    ///
    /// - Parameter data: The data to hash (typically CBOR-serialized leaf fields).
    /// - Returns: A new CID containing the SHA-256 digest.
    public static func generate(from data: Data) -> CID {
        return CID(digest: sha256Digest(data))
    }

    // MARK: - Binary Encoding

    /// Encodes the CID to its binary representation.
    ///
    /// Format: `[varint(version)][varint(codec)][varint(hashFunction)][varint(digestLength)][digest]`
    public func toBytes() -> Data {
        var data = Data()
        data.append(contentsOf: Varint.encode(version))
        data.append(contentsOf: Varint.encode(codec))
        data.append(contentsOf: Varint.encode(hashFunction))
        data.append(contentsOf: Varint.encode(UInt64(digest.count)))
        data.append(digest)
        return data
    }

    /// Decodes a CID from its binary representation.
    public static func fromBytes(_ data: Data) throws -> CID {
        var offset = 0

        let (version, vLen) = try Varint.decode(data, offset: offset)
        offset += vLen
        guard version == 1 else {
            throw CIDError.invalidCIDVersion(version)
        }

        let (codec, cLen) = try Varint.decode(data, offset: offset)
        offset += cLen

        let (hashFunc, hLen) = try Varint.decode(data, offset: offset)
        offset += hLen

        let (digestLen, dLen) = try Varint.decode(data, offset: offset)
        offset += dLen

        let digestLength = Int(digestLen)
        guard offset + digestLength <= data.count else {
            throw CIDError.truncatedCID
        }

        let digest = data[offset..<(offset + digestLength)]
        return CID(version: version, codec: codec, hashFunction: hashFunc, digest: Data(digest))
    }

    // MARK: - String Encoding

    /// Encodes the CID as a multibase string.
    ///
    /// Uses base32lower with 'b' prefix, matching go-cid's default for CIDv1.
    /// This is the format stored in `DagLeaf.hash`.
    public func toString() -> String {
        let bytes = toBytes()
        return "b" + Base32Lower.encode(bytes)
    }

    /// Encodes the CID as a base58btc multibase string ('z' prefix).
    public func toBase58String() -> String {
        let bytes = toBytes()
        return "z" + Base58BTC.encode(bytes)
    }

    /// Decodes a CID from a multibase string.
    ///
    /// Supports:
    ///   - 'b' prefix: base32lower (go-cid default for CIDv1)
    ///   - 'z' prefix: base58btc
    ///
    /// This mirrors Go's `cid.Decode(string)`.
    public static func decode(_ string: String) throws -> CID {
        guard let first = string.first else {
            throw CIDError.invalidCIDString
        }

        let payload = String(string.dropFirst())

        let bytes: Data
        switch first {
        case "b":
            bytes = try Base32Lower.decode(payload)
        case "z":
            bytes = try Base58BTC.decode(payload)
        default:
            throw CIDError.invalidMultibasePrefix(first)
        }

        return try fromBytes(bytes)
    }

    // MARK: - Comparison

    /// Checks if two CIDs are equal (matching Go's `c.Equals(other)`).
    public func equals(_ other: CID) -> Bool {
        return self == other
    }
}

// MARK: - CustomStringConvertible

extension CID: CustomStringConvertible {
    public var description: String {
        toString()
    }
}
