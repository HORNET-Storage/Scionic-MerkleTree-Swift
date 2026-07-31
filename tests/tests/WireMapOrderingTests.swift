import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Pins the wire map comparator across all three ports.
///
/// Every map key the spec-vector corpus exercises is a CID of uniform length,
/// where length-first and plain-lexicographic ordering coincide -- so the corpus
/// cannot tell the two apart. AdditionalData is the one wire map with arbitrary,
/// mixed-length keys, and it is empty in every corpus case.
///
/// This vector is the only thing standing between the three ports and a silent
/// divergence on that axis. The identical bytes are asserted in Go
/// (dag/sortedmap_test.go) and Rust (src/encoding.rs).
final class WireMapOrderingTests: XCTestCase {

    /// Keys sort length-first, then bytewise: mm, zz, aaaaaa -- carrying values
    /// 2, 1, 3 respectively. Plain lexicographic -- what `sortMapByKeys` uses, and
    /// what this port used before unification -- would give aaaaaa, mm, zz.
    private static let expected = "a3626d6d6132627a7a6131666161616161616133"

    private func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    func testWireMapsSortLengthFirstThenBytewise() {
        let encoder = CBOREncoder()
        let encoded = encoder.encode(CBOREncoder.sortedCBORMap([
            ("zz", .textString("1")),
            ("aaaaaa", .textString("3")),
            ("mm", .textString("2")),
        ]))
        XCTAssertEqual(
            hex(encoded), Self.expected,
            "wire map ordering drifted from the bytes Go and Rust pin"
        )
    }

    func testWireMapOrderingIsIndependentOfInsertionOrder() {
        let encoder = CBOREncoder()
        let forward = encoder.encode(CBOREncoder.sortedCBORMap([
            ("mm", .textString("2")),
            ("zz", .textString("1")),
            ("aaaaaa", .textString("3")),
        ]))
        let reverse = encoder.encode(CBOREncoder.sortedCBORMap([
            ("aaaaaa", .textString("3")),
            ("zz", .textString("1")),
            ("mm", .textString("2")),
        ]))
        XCTAssertEqual(forward, reverse)
    }

    /// A Swift Dictionary has no defined iteration order, so encoding the same
    /// AdditionalData twice is a real test rather than a formality.
    func testAdditionalDataEncodingIsStableAcrossRepeatedEncodes() {
        let additionalData = ["zz": "1", "mm": "2", "aaaaaa": "3"]
        let encoder = CBOREncoder()
        let first = encoder.encode(encodeSortedMapToCBOR(additionalData))
        XCTAssertEqual(hex(first), Self.expected)
        for _ in 0..<200 {
            XCTAssertEqual(encoder.encode(encodeSortedMapToCBOR(additionalData)), first)
        }
    }
}
