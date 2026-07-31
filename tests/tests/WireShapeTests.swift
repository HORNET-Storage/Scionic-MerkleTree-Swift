import Foundation
import XCTest
@testable import ScionicMerkleTree

/// The deployed Go v2.2.6 wire shape, asserted against Swift's OWN encoder.
///
/// CrossCompatWireTests already pins golden bytes captured from a deployed Go
/// build, and it is the guard that caught a wire-format regression the entire Go
/// suite passed straight through (118/118). But it has three holes that Go
/// (dag/wireshape_test.go) and Rust (tests/wire_shape.rs) now cover and this port
/// did not:
///
///  1. It only inspects BATCHED PACKETS. The full-DAG envelope -- Dag.toCBOR(),
///     the shape written to disk and read by every relay -- was never checked.
///  2. Its leaf-key helper appends "stored_proofs" to the EXPECTED list whenever
///     the leaf carries it, so it is structurally incapable of noticing
///     stored_proofs appearing on leaves that hold no proofs at all.
///  3. Nothing asserted that re-encoding the same DAG twice yields the same bytes.
///
/// Hole 2 is not hypothetical: it is exactly the second regression that shipped.
/// Declaring Go's map fields as a cbor.Marshaler made fxamacker return
/// alwaysNotEmpty for them (getEncodeFuncInternal), `omitempty` stopped firing in
/// BOTH OmitEmpty modes, and every leaf in every full DAG grew an empty
/// stored_proofs key it had never carried.
///
/// No port should be carrying a wire-shape hole the other two have closed.
final class WireShapeTests: XCTestCase {

    private static let deployedLeafKeyOrder = [
        "Hash", "ItemName", "Type", "ContentHash", "Content", "ClassicMerkleRoot",
        "CurrentLinkCount", "LeafCount", "ContentSize", "DagSize", "Links", "AdditionalData",
    ]

    private static let deployedBatchKeyOrder = ["Leaves", "Relationships", "PacketIndex", "TotalPackets"]

    private static let deployedDagKeyOrder = ["Root", "Leafs"]

    private var tempDir: String?

    override func tearDown() {
        if let dir = tempDir { try? FileManager.default.removeItem(atPath: dir) }
        tempDir = nil
        super.tearDown()
    }

    /// The same fixture tree Go and Rust build, and the same one the golden Go
    /// vectors were generated from: two files, one subdirectory, four leaves.
    /// Deep enough that the root has children, so transmission packets really do
    /// carry proofs.
    private func buildWireShapeFixture() throws -> Dag {
        let base = try ParityTestHelpers.makeTempDir("wire_shape")
        tempDir = base
        let repo = ParityTestHelpers.join(base, "golden-repo")
        try ParityTestHelpers.write(ParityTestHelpers.join(repo, "readme.md"), "hello golden repos")
        try ParityTestHelpers.write(ParityTestHelpers.join(repo, "docs", "guide.md"), "swift parity guide")
        return try ScionicMerkleTree.createDag(path: repo, timestampRoot: false)
    }

    /// Tolerates a trailing "stored_proofs" (it is Go's one `omitempty` field, and
    /// transmission leaves legitimately carry it) but nothing else, and never out of
    /// order. That it is TOLERATED here rather than asserted is precisely why
    /// testOmitEmptyStillDropsEmptyProofMaps exists below.
    private func assertLeafKeyOrder(_ leafMap: CBOROrderedMap, _ label: String) {
        var expected = Self.deployedLeafKeyOrder
        if leafMap.pairs.contains(where: { $0.key == "stored_proofs" }) {
            expected.append("stored_proofs")
        }
        XCTAssertEqual(leafMap.pairs.map(\.key), expected,
            "\(label): fields are NOT in declaration order")
    }

    func testWireStructFieldsRideInDeclarationOrder() throws {
        let dag = try buildWireShapeFixture()
        let decoder = CBORDecoder()

        let dagMap = try XCTUnwrap(decoder.decode(dag.toCBOR()).mapValue)
        XCTAssertEqual(dagMap.pairs.map(\.key), Self.deployedDagKeyOrder,
            "dag envelope: fields are NOT in declaration order")

        let leafsMap = try XCTUnwrap(dagMap["Leafs"]?.mapValue)
        XCTAssertFalse(leafsMap.pairs.isEmpty, "fixture DAG has no leaves")
        for pair in leafsMap.pairs {
            assertLeafKeyOrder(try XCTUnwrap(pair.value.mapValue), "dag leaf \(pair.key)")
        }

        let batches = dag.getBatchedLeafSequence()
        XCTAssertFalse(batches.isEmpty, "fixture produced no batched packets")
        let batchMap = try XCTUnwrap(decoder.decode(batches[0].toCBOR()).mapValue)
        XCTAssertEqual(batchMap.pairs.map(\.key), Self.deployedBatchKeyOrder,
            "batched packet: fields are NOT in declaration order")
        for leafValue in try XCTUnwrap(batchMap["Leaves"]?.arrayValue) {
            assertLeafKeyOrder(try XCTUnwrap(leafValue.mapValue), "packet leaf")
        }
    }

    /// Re-encodes many times rather than twice. A Swift Dictionary has no defined
    /// iteration order, so a single agreeing pair of encodes is weak evidence.
    func testWireEncodingIsReproducible() throws {
        let dag = try buildWireShapeFixture()
        let first = dag.toCBOR()
        for iteration in 1...200 {
            XCTAssertEqual(dag.toCBOR(), first, "encode #\(iteration) differs from encode #0")
        }
    }

    /// The guard CrossCompatWireTests structurally cannot provide.
    func testOmitEmptyStillDropsEmptyProofMaps() throws {
        let dag = try buildWireShapeFixture()
        let decoder = CBORDecoder()

        let dagMap = try XCTUnwrap(decoder.decode(dag.toCBOR()).mapValue)
        let leafsMap = try XCTUnwrap(dagMap["Leafs"]?.mapValue)
        for pair in leafsMap.pairs {
            let leafMap = try XCTUnwrap(pair.value.mapValue)
            XCTAssertFalse(leafMap.pairs.contains { $0.key == "stored_proofs" },
                "leaf \(pair.key) carries stored_proofs, but no leaf in a full DAG has proofs")
        }

        // ...and it must not over-fire. The transmission path is where proofs are
        // actually attached, so the key has to survive there.
        var carriesProofs = false
        for packet in dag.getLeafSequence() {
            let packetMap = try XCTUnwrap(decoder.decode(packet.toCBOR()).mapValue)
            if packetMap.pairs.contains(where: { $0.key == "proofs" }) {
                carriesProofs = true
                break
            }
        }
        XCTAssertTrue(carriesProofs,
            "no packet carried a proofs key, so omitempty is over-firing (or the fixture is too shallow to prove it)")
    }
}
