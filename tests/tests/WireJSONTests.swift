import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Pins this port's JSON against Go's `json.MarshalIndent(v, "", "  ")`.
///
/// Until these existed, Swift reached JSON through Foundation's `JSONEncoder` over
/// the Codable conformances, and a JSON document written by one port could not be
/// read by another at all: every key differed in case, key order was alphabetical
/// rather than declaration order, the separator was `"k" : v`, empty containers
/// expanded across three lines, absent optionals were omitted where Go writes
/// `null`, and the solidus was escaped. None of it was visible to the shared
/// cross-language vectors, which compare CBOR only.
///
/// The byte-for-byte agreement itself is proven outside the unit suite, by building
/// the same DAG in all three ports and diffing SHA-256. What these tests do is hold
/// each individually observable rule in place so a regression names itself instead
/// of showing up as one opaque hash mismatch.
final class WireJSONTests: XCTestCase {

    private var tempDir: String?

    override func tearDown() {
        if let dir = tempDir { try? FileManager.default.removeItem(atPath: dir) }
        tempDir = nil
        super.tearDown()
    }

    private func buildFixture(
        _ label: String,
        metadata: [String: String] = [:]
    ) throws -> Dag {
        let base = try ParityTestHelpers.makeTempDir(label)
        tempDir = base
        let repo = ParityTestHelpers.join(base, "json-repo")
        try ParityTestHelpers.write(ParityTestHelpers.join(repo, "readme.md"), "hello json repos")
        try ParityTestHelpers.write(ParityTestHelpers.join(repo, "docs", "guide.md"), "swift json guide")
        return try createDagAdvanced(path: repo, additionalData: metadata)
    }

    private func json(_ dag: Dag) throws -> String {
        return String(decoding: try dag.toJSON(), as: UTF8.self)
    }

    // MARK: - Formatting

    /// Go's indenting encoder, rule by rule.
    func testJSONMatchesGoMarshalIndentFormatting() throws {
        let text = try json(try buildFixture("json_format"))

        // Two-space indent, `": "` separator, declaration order (Root before Leafs).
        XCTAssertTrue(
            text.hasPrefix("{\n  \"Root\": \""),
            "document must open with a 2-space indented Root using Go's `\": \"` separator"
        )
        XCTAssertTrue(text.hasSuffix("\n}"), "document must close on its own line")

        // Foundation writes `"k" : v`. Go never does.
        XCTAssertFalse(text.contains("\" : "), "found Foundation's `\" : \"` separator")

        // Empty containers are compact. Every non-root leaf here has empty
        // AdditionalData, and the leaf files have no links.
        XCTAssertTrue(text.contains("\"AdditionalData\": {}"), "empty map must be `{}`")
        XCTAssertTrue(text.contains("\"Links\": []"), "empty array must be `[]`")

        // Absent optionals are `null`, not omitted -- Go marshals a nil []byte that
        // way, and a reader that expects the key would otherwise see it vanish.
        XCTAssertTrue(text.contains(": null"), "absent optionals must serialize as null")

        // stored_proofs stays omitted on a full DAG (Go tags it omitempty).
        XCTAssertFalse(
            text.contains("stored_proofs"),
            "a full DAG carries no proofs, so the key must be absent entirely"
        )
    }

    /// The solidus is NOT escaped, and `<`, `>`, `&` ARE.
    ///
    /// Both are Go behaviours rather than JSON requirements. Go's encoder defaults to
    /// SetEscapeHTML(true), so marshalled output is safe to embed in HTML; and it
    /// leaves `/` alone, which matters because base64 uses it heavily -- escaping it
    /// was the single highest-volume difference against Foundation.
    func testSolidusIsUnescapedAndHTMLCharactersAreEscaped() throws {
        let dag = try buildFixture("json_escapes", metadata: [
            "probe-solidus": "a/b",
            "probe-html": "<x>&y",
        ])
        let text = try json(dag)

        XCTAssertTrue(text.contains("\"a/b\""), "solidus must not be escaped")
        XCTAssertFalse(text.contains("a\\/b"), "found Foundation's escaped solidus")
        XCTAssertTrue(
            text.contains("\\u003cx\\u003e\\u0026y"),
            "`<`, `>` and `&` must be escaped the way Go's encoder does"
        )
    }

    // MARK: - Ordering

    /// The two formats sort dynamic map keys by DIFFERENT rules, and both are
    /// deliberate: CBOR is RFC 8949 length-first, JSON is Go's plain bytewise.
    ///
    /// Nothing else in the suite can catch this. The other four dynamic wire maps are
    /// keyed by CIDs, which are always exactly 59 characters, so both comparators
    /// agree on every key they can hold. AdditionalData is the only one keyed by
    /// arbitrary strings. Reordering also preserves byte length exactly, so a size
    /// check would not notice either.
    func testJSONSortsDynamicMapKeysBytewiseWhileCBORSortsLengthFirst() throws {
        let dag = try buildFixture("json_key_order", metadata: [
            "zz-probe": "1",
            "aaa-probe": "2",
        ])

        let text = try json(dag)
        guard let jsonZZ = text.range(of: "\"zz-probe\":"),
              let jsonAAA = text.range(of: "\"aaa-probe\":") else {
            return XCTFail("AdditionalData probe keys are missing from the JSON")
        }
        XCTAssertTrue(
            jsonAAA.lowerBound < jsonZZ.lowerBound,
            "JSON must sort dynamic map keys bytewise (aaa-probe before zz-probe)"
        )

        // Same DAG, same map, opposite order in CBOR.
        let cbor = dag.toCBOR()
        guard let cborZZ = range(of: "zz-probe", in: cbor),
              let cborAAA = range(of: "aaa-probe", in: cbor) else {
            return XCTFail("AdditionalData probe keys are missing from the CBOR")
        }
        XCTAssertTrue(
            cborZZ < cborAAA,
            "CBOR must sort dynamic map keys length-first (zz-probe before aaa-probe)"
        )
    }

    private func range(of needle: String, in haystack: Data) -> Int? {
        // Prefixed with the CBOR text-string head so a key cannot be confused with
        // identical bytes appearing inside leaf content.
        var pattern = Data([0x60 + UInt8(needle.utf8.count)])
        pattern.append(contentsOf: Array(needle.utf8))
        return haystack.range(of: pattern).map { $0.lowerBound }
    }

    // MARK: - Round trips

    func testDagJSONRoundTripsToIdenticalBytes() throws {
        let dag = try buildFixture("json_roundtrip", metadata: ["zz-probe": "1", "aaa-probe": "2"])
        let restored = try Dag.fromJSON(try dag.toJSON())

        XCTAssertEqual(restored.root, dag.root)
        XCTAssertEqual(restored.leafs.count, dag.leafs.count)
        XCTAssertEqual(restored.toCBOR(), dag.toCBOR(), "JSON round trip lost or altered data")
        XCTAssertEqual(try restored.toJSON(), try dag.toJSON())
    }

    /// Transmission packets are the case that actually carries proofs, so this is the
    /// only round trip that exercises stored_proofs / proofs and the base64 Siblings
    /// arrays nested inside them.
    func testTransmissionPacketJSONRoundTripsIncludingProofs() throws {
        let dag = try buildFixture("json_packets")
        let packets = dag.getLeafSequence()
        XCTAssertFalse(packets.isEmpty, "fixture produced no packets")

        var sawProofs = false
        for packet in packets {
            let restored = try TransmissionPacket.fromJSON(try packet.toJSON())
            XCTAssertEqual(restored.toCBOR(), packet.toCBOR(), "packet round trip diverged")
            if !packet.proofs.isEmpty { sawProofs = true }
        }
        XCTAssertTrue(sawProofs, "no packet carried proofs, so the proof path went untested")
    }

    func testBatchedPacketJSONRoundTrips() throws {
        let dag = try buildFixture("json_batched")
        let batches = dag.getBatchedLeafSequence()
        XCTAssertFalse(batches.isEmpty, "fixture produced no batched packets")

        for batch in batches {
            let restored = try BatchedTransmissionPacket.fromJSON(try batch.toJSON())
            XCTAssertEqual(restored.toCBOR(), batch.toCBOR(), "batched packet round trip diverged")
        }
    }

    /// A partial DAG carries stored_proofs on its leaves and has pruned links, so it
    /// is a genuinely different encode path from a full DAG.
    func testPartialDagJSONRoundTripsIncludingStoredProofs() throws {
        let dag = try buildFixture("json_partial")
        guard let target = dag.leafs.values.first(where: { $0.type == .file })?.hash else {
            return XCTFail("fixture has no file leaf to build a partial from")
        }
        let partial = try dag.getPartial(leafHashes: [target], pruneLinks: true)

        let text = String(decoding: try partial.toJSON(), as: UTF8.self)
        XCTAssertTrue(
            text.contains("stored_proofs"),
            "a partial DAG must carry stored_proofs, or this asserts nothing about them"
        )

        let restored = try Dag.fromJSON(try partial.toJSON())
        XCTAssertEqual(restored.toCBOR(), partial.toCBOR(), "partial DAG round trip diverged")
    }

    // MARK: - Cross-format agreement

    /// Both writers read the SAME wire tree, so the field names they emit cannot
    /// drift apart. This asserts that structurally rather than by inspection.
    func testJSONAndCBORCarryTheSameFieldNames() throws {
        let dag = try buildFixture("json_field_names")
        let text = try json(dag)

        for key in [
            "Root", "Leafs", "Hash", "ItemName", "Type", "ContentHash", "Content",
            "ClassicMerkleRoot", "CurrentLinkCount", "LeafCount", "ContentSize",
            "DagSize", "Links", "AdditionalData",
        ] {
            XCTAssertTrue(text.contains("\"\(key)\":"), "JSON is missing wire key \(key)")
        }

        // camelCase is what the old Codable path emitted; none of it may survive.
        for stale in ["\"root\":", "\"leafs\":", "\"itemName\":", "\"contentHash\":"] {
            XCTAssertFalse(text.contains(stale), "found stale Codable spelling \(stale)")
        }
    }
}
