import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Pins the wire map comparators across all three ports.
///
/// Every map key the spec-vector corpus exercises is a CID of uniform length -- 59
/// characters, always -- where length-first and plain-bytewise ordering coincide, so
/// the corpus cannot tell the two apart. AdditionalData is the one wire map with
/// arbitrary, mixed-length keys, and it is empty in every corpus case.
///
/// These vectors are the only thing standing between the three ports and a silent
/// divergence on that axis. The identical bytes are asserted in Go
/// (dag/sortedmap_test.go) and Rust (src/encoding.rs).
final class WireMapOrderingTests: XCTestCase {

    /// Keys sort length-first, then bytewise: mm, zz, aaaaaa -- carrying values
    /// 2, 1, 3 respectively. Plain bytewise -- what `sortMapByKeys` uses, and what
    /// this port used before unification -- would give aaaaaa, mm, zz.
    private static let expected = "a3626d6d6132627a7a6131666161616161616133"

    private func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    func testWireMapsSortLengthFirstThenBytewise() {
        let encoder = CBOREncoder()
        let encoded = encoder.encode(CBOREncoder.sortedWireMap([
            ("zz", .textString("1")),
            ("aaaaaa", .textString("3")),
            ("mm", .textString("2")),
        ], order: .cbor))
        XCTAssertEqual(
            hex(encoded), Self.expected,
            "wire map ordering drifted from the bytes Go and Rust pin"
        )
    }

    func testWireMapOrderingIsIndependentOfInsertionOrder() {
        let encoder = CBOREncoder()
        let forward = encoder.encode(CBOREncoder.sortedWireMap([
            ("mm", .textString("2")),
            ("zz", .textString("1")),
            ("aaaaaa", .textString("3")),
        ], order: .cbor))
        let reverse = encoder.encode(CBOREncoder.sortedWireMap([
            ("aaaaaa", .textString("3")),
            ("zz", .textString("1")),
            ("mm", .textString("2")),
        ], order: .cbor))
        XCTAssertEqual(forward, reverse)
    }

    /// A Swift Dictionary has no defined iteration order, so encoding the same
    /// AdditionalData twice is a real test rather than a formality.
    func testAdditionalDataEncodingIsStableAcrossRepeatedEncodes() {
        let additionalData = ["zz": "1", "mm": "2", "aaaaaa": "3"]
        let encoder = CBOREncoder()
        let first = encoder.encode(encodeSortedMapToCBOR(additionalData, order: .cbor))
        XCTAssertEqual(hex(first), Self.expected)
        for _ in 0..<200 {
            XCTAssertEqual(
                encoder.encode(encodeSortedMapToCBOR(additionalData, order: .cbor)),
                first
            )
        }
    }

    /// Pins the JSON comparator, which is deliberately NOT the CBOR one.
    ///
    /// Go reaches JSON through `encoding/json`, which sorts map keys with a plain
    /// bytewise compare and no length term. On these same three keys the two rules
    /// disagree completely:
    ///
    ///     CBOR (length-first): mm, zz, aaaaaa
    ///     JSON (bytewise):     aaaaaa, mm, zz
    ///
    /// The Rust port emitted the CBOR order into JSON until this was caught, and
    /// nothing in the cross-port machinery could see it: the shared vectors compared
    /// CBOR only, and the one wire map with mixed-length keys (AdditionalData) is
    /// empty in every vector and every benchmark-corpus leaf.
    func testJSONWireMapsSortBytewiseAndCBORMapsDoNot() {
        func keys(_ order: WireKeyOrder) -> [String] {
            guard case .map(let ordered) = CBOREncoder.sortedWireMap([
                ("zz", .textString("1")),
                ("aaaaaa", .textString("3")),
                ("mm", .textString("2")),
            ], order: order) else {
                XCTFail("sortedWireMap must produce a map")
                return []
            }
            return ordered.pairs.map { $0.key }
        }

        XCTAssertEqual(keys(.cbor), ["mm", "zz", "aaaaaa"])
        XCTAssertEqual(keys(.json), ["aaaaaa", "mm", "zz"])
    }
}
