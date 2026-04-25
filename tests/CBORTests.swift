import XCTest
@testable import ScionicMerkleTree

final class CBORTests: XCTestCase {
    let encoder = CBOREncoder()
    let decoder = CBORDecoder()

    // MARK: - Encoder: Unsigned Integers

    func testEncodeUnsignedIntSmall() {
        // 0-23 → single byte [major | value]
        XCTAssertEqual(encoder.encode(.unsignedInt(0)), Data([0x00]))
        XCTAssertEqual(encoder.encode(.unsignedInt(1)), Data([0x01]))
        XCTAssertEqual(encoder.encode(.unsignedInt(10)), Data([0x0a]))
        XCTAssertEqual(encoder.encode(.unsignedInt(23)), Data([0x17]))
    }

    func testEncodeUnsignedInt1Byte() {
        // 24-255 → [0x18, value]
        XCTAssertEqual(encoder.encode(.unsignedInt(24)), Data([0x18, 0x18]))
        XCTAssertEqual(encoder.encode(.unsignedInt(42)), Data([0x18, 0x2a]))
        XCTAssertEqual(encoder.encode(.unsignedInt(255)), Data([0x18, 0xff]))
    }

    func testEncodeUnsignedInt2Bytes() {
        // 256-65535 → [0x19, hi, lo]
        XCTAssertEqual(encoder.encode(.unsignedInt(256)), Data([0x19, 0x01, 0x00]))
        XCTAssertEqual(encoder.encode(.unsignedInt(1000)), Data([0x19, 0x03, 0xe8]))
        XCTAssertEqual(encoder.encode(.unsignedInt(65535)), Data([0x19, 0xff, 0xff]))
    }

    func testEncodeUnsignedInt4Bytes() {
        // 65536-2^32-1 → [0x1a, 4 bytes BE]
        XCTAssertEqual(encoder.encode(.unsignedInt(65536)), Data([0x1a, 0x00, 0x01, 0x00, 0x00]))
        XCTAssertEqual(encoder.encode(.unsignedInt(1_000_000)), Data([0x1a, 0x00, 0x0f, 0x42, 0x40]))
    }

    func testEncodeUnsignedInt8Bytes() {
        // > 2^32-1 → [0x1b, 8 bytes BE]
        let large: UInt64 = 0x0100000000 // 2^32
        XCTAssertEqual(encoder.encode(.unsignedInt(large)), Data([0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
    }

    // MARK: - Encoder: Negative Integers

    func testEncodeNegativeInt() {
        // CBOR negative int: -1 → n=0 → [0x20]
        XCTAssertEqual(encoder.encode(.negativeInt(-1)), Data([0x20]))
        // -10 → n=9 → [0x29]
        XCTAssertEqual(encoder.encode(.negativeInt(-10)), Data([0x29]))
        // -100 → n=99 → [0x38, 0x63]
        XCTAssertEqual(encoder.encode(.negativeInt(-100)), Data([0x38, 0x63]))
    }

    // MARK: - Encoder: Byte Strings

    func testEncodeByteStringEmpty() {
        // Empty byte string → [0x40]
        XCTAssertEqual(encoder.encode(.byteString(Data())), Data([0x40]))
    }

    func testEncodeByteString() {
        // 4 bytes → [0x44, bytes...]
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(encoder.encode(.byteString(bytes)), Data([0x44, 0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: - Encoder: Text Strings

    func testEncodeTextStringEmpty() {
        // Empty text string → [0x60]
        XCTAssertEqual(encoder.encode(.textString("")), Data([0x60]))
    }

    func testEncodeTextString() {
        // "hello" → [0x65, h, e, l, l, o]
        XCTAssertEqual(
            encoder.encode(.textString("hello")),
            Data([0x65, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        )
    }

    func testEncodeTextStringFile() {
        // "file" — the LeafType used for files
        XCTAssertEqual(
            encoder.encode(.textString("file")),
            Data([0x64, 0x66, 0x69, 0x6c, 0x65])
        )
    }

    // MARK: - Encoder: Arrays

    func testEncodeArrayEmpty() {
        // Empty array → [0x80]
        XCTAssertEqual(encoder.encode(.array([])), Data([0x80]))
    }

    func testEncodeArrayOfInts() {
        // [1, 2, 3] → [0x83, 0x01, 0x02, 0x03]
        XCTAssertEqual(
            encoder.encode(.array([.unsignedInt(1), .unsignedInt(2), .unsignedInt(3)])),
            Data([0x83, 0x01, 0x02, 0x03])
        )
    }

    // MARK: - Encoder: Maps

    func testEncodeMapEmpty() {
        // Empty map → [0xa0]
        XCTAssertEqual(encoder.encodeMap([]), Data([0xa0]))
    }

    func testEncodeMapSingleEntry() {
        // {"Key": "val"} → [0xa1, 0x63, K, e, y, 0x63, v, a, l]
        let data = encoder.encodeMap([("Key", .textString("val"))])
        XCTAssertEqual(data, Data([0xa1, 0x63, 0x4b, 0x65, 0x79, 0x63, 0x76, 0x61, 0x6c]))
    }

    func testEncodeMapPreservesOrder() {
        // Verify field order is preserved (not sorted alphabetically)
        let data1 = encoder.encodeMap([("B", .unsignedInt(1)), ("A", .unsignedInt(2))])
        let data2 = encoder.encodeMap([("A", .unsignedInt(2)), ("B", .unsignedInt(1))])
        // These must be DIFFERENT because order matters
        XCTAssertNotEqual(data1, data2)
    }

    // MARK: - Encoder: Simple Values

    func testEncodeNull() {
        XCTAssertEqual(encoder.encode(.null), Data([0xf6]))
    }

    func testEncodeBool() {
        XCTAssertEqual(encoder.encode(.bool(false)), Data([0xf4]))
        XCTAssertEqual(encoder.encode(.bool(true)), Data([0xf5]))
    }

    func testEncodeUndefined() {
        XCTAssertEqual(encoder.encode(.undefined), Data([0xf7]))
    }

    // MARK: - Encoder: Convenience Constructors

    func testIntConvenience() {
        XCTAssertEqual(CBORValue.int(0), .unsignedInt(0))
        XCTAssertEqual(CBORValue.int(42), .unsignedInt(42))
        XCTAssertEqual(CBORValue.int(-1), .negativeInt(-1))
    }

    func testInt64Convenience() {
        XCTAssertEqual(CBORValue.int64(0), .unsignedInt(0))
        XCTAssertEqual(CBORValue.int64(Int64(Int32.max) + 1), .unsignedInt(UInt64(Int32.max) + 1))
        XCTAssertEqual(CBORValue.int64(-1), .negativeInt(-1))
    }

    func testOptionalBytesConvenience() {
        XCTAssertEqual(CBORValue.optionalBytes(nil), .null)
        XCTAssertEqual(CBORValue.optionalBytes(Data()), .byteString(Data()))
        XCTAssertEqual(CBORValue.optionalBytes(Data([0xff])), .byteString(Data([0xff])))
    }

    func testOptionalArrayConvenience() {
        XCTAssertEqual(CBORValue.optionalArray(nil), .null)
        XCTAssertEqual(CBORValue.optionalArray([]), .array([]))
        XCTAssertEqual(CBORValue.optionalArray([.null]), .array([.null]))
    }

    // MARK: - Encoder: Leaf-Hashing Pattern (Go struct equivalent)

    func testEncodeLeafDataPattern() {
        // Simulate the Go BuildLeaf anonymous struct:
        //   struct {
        //       ItemName         string
        //       Type             LeafType
        //       MerkleRoot       []byte     // empty = []byte{}
        //       CurrentLinkCount int        // 0
        //       ContentHash      []byte     // nil
        //       AdditionalData   []KeyValue // nil
        //   }
        let data = encoder.encodeMap([
            ("ItemName", .textString("test.txt")),
            ("Type", .textString("file")),
            ("MerkleRoot", .byteString(Data())),         // []byte{} → 0x40
            ("CurrentLinkCount", .int(0)),                // 0 → 0x00
            ("ContentHash", .null),                       // nil → 0xf6
            ("AdditionalData", .null),                    // nil → 0xf6
        ])

        // Verify it's a 6-entry map
        XCTAssertEqual(data[0], 0xa6) // map(6)

        // Verify round-trip
        let decoded = try! decoder.decode(data)
        guard case .map(let m) = decoded else {
            XCTFail("Expected map"); return
        }
        XCTAssertEqual(m.pairs.count, 6)
        XCTAssertEqual(m["ItemName"], .textString("test.txt"))
        XCTAssertEqual(m["Type"], .textString("file"))
        XCTAssertEqual(m["MerkleRoot"], .byteString(Data()))
        XCTAssertEqual(m["CurrentLinkCount"], .unsignedInt(0))
        XCTAssertEqual(m["ContentHash"], .null)
        XCTAssertEqual(m["AdditionalData"], .null)
    }

    func testEncodeKeyValuePattern() {
        // Go's KeyValue struct: {"Key": "timestamp", "Value": "2024-01-01T00:00:00Z"}
        let kv = CBORValue.map(CBOROrderedMap([
            ("Key", .textString("timestamp")),
            ("Value", .textString("2024-01-01T00:00:00Z")),
        ]))
        let data = encoder.encode(kv)

        // Verify round-trip
        let decoded = try! decoder.decode(data)
        guard case .map(let m) = decoded else {
            XCTFail("Expected map"); return
        }
        XCTAssertEqual(m["Key"], .textString("timestamp"))
        XCTAssertEqual(m["Value"], .textString("2024-01-01T00:00:00Z"))
    }

    // MARK: - Decoder: Round-Trip

    func testRoundTripAllTypes() {
        let values: [CBORValue] = [
            .unsignedInt(0),
            .unsignedInt(42),
            .unsignedInt(1000),
            .unsignedInt(1_000_000),
            .negativeInt(-1),
            .negativeInt(-100),
            .byteString(Data()),
            .byteString(Data([0xde, 0xad, 0xbe, 0xef])),
            .textString(""),
            .textString("hello world"),
            .array([]),
            .array([.unsignedInt(1), .textString("two"), .null]),
            .map(CBOROrderedMap([])),
            .map(CBOROrderedMap([("a", .unsignedInt(1)), ("b", .textString("two"))])),
            .null,
            .bool(true),
            .bool(false),
            .undefined,
        ]

        for original in values {
            let encoded = encoder.encode(original)
            let decoded = try! decoder.decode(encoded)
            XCTAssertEqual(decoded, original, "Round-trip failed for \(original)")
        }
    }

    func testRoundTripNestedStructure() {
        // Simulate a full leaf data struct with nested KeyValue array
        let original = CBORValue.map(CBOROrderedMap([
            ("ItemName", .textString("subdir/file.dat")),
            ("Type", .textString("file")),
            ("MerkleRoot", .byteString(Data(repeating: 0xab, count: 32))),
            ("CurrentLinkCount", .int(3)),
            ("ContentHash", .byteString(Data(repeating: 0xcd, count: 32))),
            ("AdditionalData", .array([
                .map(CBOROrderedMap([("Key", .textString("author")), ("Value", .textString("test"))])),
                .map(CBOROrderedMap([("Key", .textString("version")), ("Value", .textString("1.0"))])),
            ])),
        ]))

        let encoded = encoder.encode(original)
        let decoded = try! decoder.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Decoder: Error Handling

    func testDecodeEmptyData() {
        XCTAssertThrowsError(try decoder.decode(Data())) { error in
            XCTAssertEqual(error as? CBORError, CBORError.prematureEnd)
        }
    }

    func testDecodeTruncatedByteString() {
        // Byte string claiming 4 bytes but only 2 available
        XCTAssertThrowsError(try decoder.decode(Data([0x44, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? CBORError, CBORError.prematureEnd)
        }
    }

    // MARK: - Extraction Helpers

    func testExtractionHelpers() {
        XCTAssertEqual(CBORValue.textString("hi").stringValue, "hi")
        XCTAssertNil(CBORValue.unsignedInt(1).stringValue)

        XCTAssertEqual(CBORValue.unsignedInt(42).uintValue, 42)
        XCTAssertEqual(CBORValue.unsignedInt(42).intValue, 42)
        XCTAssertEqual(CBORValue.negativeInt(-5).intValue, -5)
        XCTAssertEqual(CBORValue.negativeInt(-5).int64Value, -5)

        XCTAssertEqual(CBORValue.byteString(Data([1])).dataValue, Data([1]))
        XCTAssertNil(CBORValue.null.dataValue)

        XCTAssertNotNil(CBORValue.array([]).arrayValue)
        XCTAssertNotNil(CBORValue.map(CBOROrderedMap([])).mapValue)

        XCTAssertTrue(CBORValue.null.isNull)
        XCTAssertFalse(CBORValue.unsignedInt(0).isNull)
    }

    // MARK: - Determinism

    func testEncodingIsDeterministic() {
        // Same input must always produce same output
        let value = CBORValue.map(CBOROrderedMap([
            ("ItemName", .textString("test")),
            ("Type", .textString("file")),
            ("Count", .int(42)),
        ]))

        let data1 = encoder.encode(value)
        let data2 = encoder.encode(value)
        let data3 = encoder.encode(value)

        XCTAssertEqual(data1, data2)
        XCTAssertEqual(data2, data3)
    }
}