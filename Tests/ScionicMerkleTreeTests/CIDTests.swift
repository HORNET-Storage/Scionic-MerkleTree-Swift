import XCTest
@testable import ScionicMerkleTree

final class VarintTests: XCTestCase {

    // MARK: - Varint Encoding

    func testEncodeSmallValues() {
        // Values < 128 → single byte
        XCTAssertEqual(Varint.encode(0), Data([0x00]))
        XCTAssertEqual(Varint.encode(1), Data([0x01]))
        XCTAssertEqual(Varint.encode(0x12), Data([0x12])) // SHA2-256 code
        XCTAssertEqual(Varint.encode(0x20), Data([0x20])) // 32 bytes
        XCTAssertEqual(Varint.encode(0x51), Data([0x51])) // CBOR codec
        XCTAssertEqual(Varint.encode(0x71), Data([0x71])) // DAG-CBOR codec
        XCTAssertEqual(Varint.encode(127), Data([0x7f]))
    }

    func testEncodeMultiByteValues() {
        // 128 → [0x80, 0x01]
        XCTAssertEqual(Varint.encode(128), Data([0x80, 0x01]))
        // 300 → [0xac, 0x02]
        XCTAssertEqual(Varint.encode(300), Data([0xac, 0x02]))
        // 512 → [0x80, 0x04]
        XCTAssertEqual(Varint.encode(512), Data([0x80, 0x04]))
    }

    // MARK: - Varint Decoding

    func testDecodeSmallValues() throws {
        let (val1, len1) = try Varint.decode(Data([0x00]))
        XCTAssertEqual(val1, 0)
        XCTAssertEqual(len1, 1)

        let (val2, len2) = try Varint.decode(Data([0x51]))
        XCTAssertEqual(val2, 0x51)
        XCTAssertEqual(len2, 1)
    }

    func testDecodeMultiByte() throws {
        let (val, len) = try Varint.decode(Data([0x80, 0x01]))
        XCTAssertEqual(val, 128)
        XCTAssertEqual(len, 2)
    }

    func testDecodeWithOffset() throws {
        // Skip first byte, decode from offset 1
        let data = Data([0xff, 0x51])
        let (val, len) = try Varint.decode(data, offset: 1)
        XCTAssertEqual(val, 0x51)
        XCTAssertEqual(len, 1)
    }

    // MARK: - Varint Round-Trip

    func testRoundTrip() throws {
        let values: [UInt64] = [0, 1, 0x12, 0x20, 0x51, 0x71, 127, 128, 255, 256, 300, 512, 1000, 65535, 100000]
        for original in values {
            let encoded = Varint.encode(original)
            let (decoded, _) = try Varint.decode(encoded)
            XCTAssertEqual(decoded, original, "Round-trip failed for \(original)")
        }
    }

    func testDecodeTruncated() {
        // Continuation bit set but no more bytes
        XCTAssertThrowsError(try Varint.decode(Data([0x80]))) { error in
            XCTAssertEqual(error as? CIDError, CIDError.truncatedVarint)
        }
    }
}

final class Base32LowerTests: XCTestCase {

    func testEncodeEmpty() {
        XCTAssertEqual(Base32Lower.encode(Data()), "")
    }

    func testEncodeKnownValues() {
        // RFC 4648 test vectors (lowercased, no padding)
        XCTAssertEqual(Base32Lower.encode(Data("f".utf8)), "my")
        XCTAssertEqual(Base32Lower.encode(Data("fo".utf8)), "mzxq")
        XCTAssertEqual(Base32Lower.encode(Data("foo".utf8)), "mzxw6")
        XCTAssertEqual(Base32Lower.encode(Data("foob".utf8)), "mzxw6yq")
        XCTAssertEqual(Base32Lower.encode(Data("fooba".utf8)), "mzxw6ytb")
        XCTAssertEqual(Base32Lower.encode(Data("foobar".utf8)), "mzxw6ytboi")
    }

    func testRoundTrip() throws {
        let testData: [Data] = [
            Data([0x01, 0x51, 0x12, 0x20]),  // CID prefix bytes
            Data(repeating: 0xab, count: 32),  // hash-like data
            Data("hello world".utf8),
            Data([0x00]),                       // single zero
            Data([0x00, 0x00, 0xff]),           // leading zeros
        ]

        for original in testData {
            let encoded = Base32Lower.encode(original)
            let decoded = try Base32Lower.decode(encoded)
            XCTAssertEqual(decoded, original, "Base32 round-trip failed for \(original.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func testDecodeInvalidCharacter() {
        XCTAssertThrowsError(try Base32Lower.decode("!!!")) { error in
            XCTAssertEqual(error as? CIDError, CIDError.invalidBase32Character)
        }
    }
}

final class Base58BTCTests: XCTestCase {

    func testEncodeEmpty() {
        XCTAssertEqual(Base58BTC.encode(Data()), "")
    }

    func testEncodeKnownValues() {
        // Well-known base58 test vectors
        XCTAssertEqual(Base58BTC.encode(Data("Hello World!".utf8)), "2NEpo7TZRRrLZSi2U")
        XCTAssertEqual(Base58BTC.encode(Data([0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd])), "11233QC4")
    }

    func testEncodeLeadingZeros() {
        // Leading zero bytes → leading '1's
        XCTAssertEqual(Base58BTC.encode(Data([0x00])), "1")
        XCTAssertEqual(Base58BTC.encode(Data([0x00, 0x00])), "11")
    }

    func testRoundTrip() throws {
        let testData: [Data] = [
            Data([0x01, 0x51, 0x12, 0x20]),
            Data(repeating: 0xab, count: 32),
            Data("hello world".utf8),
            Data([0x00]),
            Data([0x00, 0x00, 0xff]),
        ]

        for original in testData {
            let encoded = Base58BTC.encode(original)
            let decoded = try Base58BTC.decode(encoded)
            XCTAssertEqual(decoded, original, "Base58 round-trip failed for \(original.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func testDecodeInvalidCharacter() {
        // '0' is not in base58 alphabet
        XCTAssertThrowsError(try Base58BTC.decode("0invalid")) { error in
            XCTAssertEqual(error as? CIDError, CIDError.invalidBase58Character)
        }
    }
}

final class CIDTests: XCTestCase {

    // MARK: - CID Generation

    func testGenerateFromData() {
        let data = Data("hello world".utf8)
        let cid = CID.generate(from: data)

        XCTAssertEqual(cid.version, 1)
        XCTAssertEqual(cid.codec, Multicodec.cbor)
        XCTAssertEqual(cid.hashFunction, MultihashCode.sha2_256)
        XCTAssertEqual(cid.digest.count, 32)
    }

    func testGenerateDeterministic() {
        let data = Data("test data for CID".utf8)
        let cid1 = CID.generate(from: data)
        let cid2 = CID.generate(from: data)

        XCTAssertEqual(cid1, cid2)
        XCTAssertEqual(cid1.toString(), cid2.toString())
    }

    func testDifferentDataProducesDifferentCIDs() {
        let cid1 = CID.generate(from: Data("data1".utf8))
        let cid2 = CID.generate(from: Data("data2".utf8))

        XCTAssertNotEqual(cid1, cid2)
    }

    // MARK: - Binary Encoding

    func testToBytesFormat() {
        let digest = Data(repeating: 0xab, count: 32)
        let cid = CID(digest: digest)
        let bytes = cid.toBytes()

        // [0x01=version][0x51=cbor][0x12=sha256][0x20=32bytes][32 bytes digest]
        XCTAssertEqual(bytes.count, 36)
        XCTAssertEqual(bytes[0], 0x01) // CIDv1
        XCTAssertEqual(bytes[1], 0x51) // CBOR codec
        XCTAssertEqual(bytes[2], 0x12) // SHA2-256
        XCTAssertEqual(bytes[3], 0x20) // 32 bytes
        XCTAssertEqual(Data(bytes[4...]), digest)
    }

    func testBinaryRoundTrip() throws {
        let cid = CID.generate(from: Data("round trip test".utf8))
        let bytes = cid.toBytes()
        let decoded = try CID.fromBytes(bytes)

        XCTAssertEqual(cid, decoded)
    }

    // MARK: - String Encoding (Base32Lower)

    func testToStringStartsWithB() {
        let cid = CID.generate(from: Data("test".utf8))
        let str = cid.toString()

        // go-cid CIDv1 default: 'b' + base32lower
        XCTAssertTrue(str.hasPrefix("b"))
        // All lowercase after prefix
        XCTAssertEqual(str, str.lowercased())
    }

    func testStringRoundTrip() throws {
        let cid = CID.generate(from: Data("string round trip".utf8))
        let str = cid.toString()
        let decoded = try CID.decode(str)

        XCTAssertEqual(cid, decoded)
    }

    // MARK: - String Encoding (Base58BTC)

    func testToBase58StringStartsWithZ() {
        let cid = CID.generate(from: Data("test".utf8))
        let str = cid.toBase58String()

        XCTAssertTrue(str.hasPrefix("z"))
    }

    func testBase58StringRoundTrip() throws {
        let cid = CID.generate(from: Data("base58 round trip".utf8))
        let str = cid.toBase58String()
        let decoded = try CID.decode(str)

        XCTAssertEqual(cid, decoded)
    }

    // MARK: - Cross-Format Compatibility

    func testBase32AndBase58ProduceSameCID() throws {
        let cid = CID.generate(from: Data("cross format".utf8))

        let b32 = cid.toString()
        let b58 = cid.toBase58String()

        // Different strings
        XCTAssertNotEqual(b32, b58)

        // But decode to same CID
        let fromB32 = try CID.decode(b32)
        let fromB58 = try CID.decode(b58)
        XCTAssertEqual(fromB32, fromB58)
    }

    // MARK: - CID.equals

    func testEquals() {
        let cid1 = CID.generate(from: Data("same".utf8))
        let cid2 = CID.generate(from: Data("same".utf8))
        let cid3 = CID.generate(from: Data("different".utf8))

        XCTAssertTrue(cid1.equals(cid2))
        XCTAssertFalse(cid1.equals(cid3))
    }

    // MARK: - End-to-End: CBOR → CID (mirrors Go leaf hashing)

    func testCBORToCIDPipeline() throws {
        // Simulate the Go leaf hashing pipeline:
        // 1. CBOR-encode a struct
        // 2. Generate CID from the encoded bytes
        // 3. Store as string
        // 4. Decode and verify

        let encoder = CBOREncoder()
        let leafData = encoder.encodeMap([
            ("ItemName", .textString("test.txt")),
            ("Type", .textString("file")),
            ("MerkleRoot", .byteString(Data())),
            ("CurrentLinkCount", .int(0)),
            ("ContentHash", .null),
            ("AdditionalData", .null),
        ])

        let cid = CID.generate(from: leafData)
        let hashString = cid.toString()

        // Verify: decode the string, regenerate CID, compare
        let decodedCID = try CID.decode(hashString)
        let regeneratedCID = CID.generate(from: leafData)

        XCTAssertEqual(decodedCID, regeneratedCID)
        XCTAssertTrue(decodedCID.equals(regeneratedCID))
    }

    // MARK: - Error Cases

    func testDecodeEmptyString() {
        XCTAssertThrowsError(try CID.decode("")) { error in
            XCTAssertEqual(error as? CIDError, CIDError.invalidCIDString)
        }
    }

    func testDecodeInvalidPrefix() {
        XCTAssertThrowsError(try CID.decode("xinvalid")) { error in
            XCTAssertEqual(error as? CIDError, CIDError.invalidMultibasePrefix("x"))
        }
    }

    func testFromBytesTruncated() {
        // Just a version byte, missing everything else
        XCTAssertThrowsError(try CID.fromBytes(Data([0x01])))
    }

    func testFromBytesInvalidVersion() {
        // Version 0 is not supported (CIDv0 has different format)
        XCTAssertThrowsError(try CID.fromBytes(Data([0x00, 0x51, 0x12, 0x20]))) { error in
            XCTAssertEqual(error as? CIDError, CIDError.invalidCIDVersion(0))
        }
    }

    // MARK: - Constants

    func testMulticodecConstants() {
        XCTAssertEqual(Multicodec.cbor, 0x51)
        XCTAssertEqual(Multicodec.dagCBOR, 0x71)
    }

    func testMultihashConstants() {
        XCTAssertEqual(MultihashCode.sha2_256, 0x12)
        XCTAssertEqual(MultihashCode.sha2_256DigestLength, 32)
    }
}