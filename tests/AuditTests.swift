import XCTest
@testable import ScionicMerkleTree

/// Tests for audit findings — clone independence, serialization round-trip, etc.
final class AuditTests: XCTestCase {

    // MARK: - #26: Clone deep-copy verification

    func testCloneIsIndependent() throws {
        let original = DagLeaf()
        original.hash = "original_hash"
        original.itemName = "test.txt"
        original.type = .file
        original.content = Data("hello".utf8)
        original.contentHash = Data(repeating: 0xab, count: 32)
        original.links = ["link1", "link2"]
        original.additionalData = ["key": "value"]
        original.proofs = ["proof1": ClassicTreeBranch(leaf: "proof1", proof: Proof(siblings: [Data(repeating: 0xcd, count: 32)], path: 1))]

        let cloned = original.clone()

        // Verify values match
        XCTAssertEqual(cloned.hash, original.hash)
        XCTAssertEqual(cloned.links, original.links)
        XCTAssertEqual(cloned.additionalData, original.additionalData)
        XCTAssertEqual(cloned.proofs.count, original.proofs.count)

        // Modify the clone — original should NOT be affected
        cloned.hash = "modified_hash"
        cloned.links.append("link3")
        cloned.additionalData["new"] = "data"
        cloned.proofs["proof2"] = ClassicTreeBranch(leaf: "proof2", proof: Proof())
        cloned.content = Data("modified".utf8)

        // Original unchanged
        XCTAssertEqual(original.hash, "original_hash")
        XCTAssertEqual(original.links, ["link1", "link2"])
        XCTAssertEqual(original.additionalData, ["key": "value"])
        XCTAssertEqual(original.proofs.count, 1)
        XCTAssertEqual(original.content, Data("hello".utf8))

        // Clone has new values
        XCTAssertEqual(cloned.hash, "modified_hash")
        XCTAssertEqual(cloned.links, ["link1", "link2", "link3"])
        XCTAssertEqual(cloned.additionalData.count, 2)
        XCTAssertEqual(cloned.proofs.count, 2)
    }

    // MARK: - JSON Serialization Round-Trip

    func testJsonSerializationRoundTrip() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "json_roundtrip_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input + "/sub", withIntermediateDirectories: true)
        try "file content".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/a.txt"))
        try "nested content".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/sub/b.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        let originalRoot = dag.root

        // Serialize to JSON
        let jsonData = try dag.toJSON()
        XCTAssertFalse(jsonData.isEmpty)

        // Deserialize
        let restored = try Dag.fromJSON(jsonData)
        XCTAssertEqual(restored.root, originalRoot)
        XCTAssertEqual(restored.leafs.count, dag.leafs.count)

        // Verify the restored DAG
        try restored.verify()

        // Recreate directory and check content
        let outputDir = tmpDir + "/output"
        try restored.createDirectory(path: outputDir)
        let content = try String(contentsOfFile: outputDir + "/a.txt", encoding: .utf8)
        XCTAssertEqual(content, "file content")
        let nested = try String(contentsOfFile: outputDir + "/sub/b.txt", encoding: .utf8)
        XCTAssertEqual(nested, "nested content")
    }

    // MARK: - CBOR Serialization Round-Trip

    func testCborSerializationRoundTrip() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "cbor_roundtrip_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try "cbor test data".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/test.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)

        // CBOR round-trip
        let cborData = dag.toCBOR()
        XCTAssertFalse(cborData.isEmpty)

        let restored = try Dag.fromCBOR(cborData)
        XCTAssertEqual(restored.root, dag.root)
        XCTAssertEqual(restored.leafs.count, dag.leafs.count)
        try restored.verify()
    }

    // MARK: - TransmissionPacket Serialization Round-Trip

    func testTransmissionPacketJsonRoundTrip() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "packet_roundtrip_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try "packet test".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/file.txt"))
        try "packet test 2".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/file2.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        let packets = dag.getLeafSequence()
        XCTAssertGreaterThan(packets.count, 0)

        // Round-trip each packet through JSON
        for packet in packets {
            let jsonData = try packet.toJSON()
            XCTAssertFalse(jsonData.isEmpty)
            let restored = try TransmissionPacket.fromJSON(jsonData)
            XCTAssertEqual(restored.leaf.hash, packet.leaf.hash)
            XCTAssertEqual(restored.parentHash, packet.parentHash)
        }
    }

    // MARK: - DagStore Basic Operations

    func testDagStoreBasicOperations() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "store_test_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input + "/docs", withIntermediateDirectories: true)
        try "readme".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/readme.txt"))
        try "guide".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/docs/guide.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)

        // Create store
        let store = DagStore(dag)
        XCTAssertEqual(store.root, dag.root)

        // Retrieve leaf
        let rootLeaf = try store.retrieveLeaf(store.root)
        XCTAssertNotNil(rootLeaf)
        XCTAssertEqual(rootLeaf?.hash, dag.root)

        // Verify
        try store.verify()

        // ToDag round-trip
        let restored = try store.toDag()
        XCTAssertEqual(restored.root, dag.root)
        try restored.verify()

        // Labels
        try store.calculateLabels()
        XCTAssertFalse(store.labels.isEmpty)
        let rootLabel = try store.getLabel(hash: store.root)
        XCTAssertEqual(rootLabel, "0")
    }

    // MARK: - Transmission Simulation

    func testTransmissionSimulation() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "transmission_sim_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input + "/sub", withIntermediateDirectories: true)
        try "data1".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/a.txt"))
        try "data2".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/sub/b.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        let packets = dag.getLeafSequence()
        XCTAssertGreaterThan(packets.count, 0)

        let receiver = Dag()
        for packet in packets {
            try receiver.applyAndVerifyTransmissionPacket(packet)
        }

        XCTAssertEqual(receiver.root, dag.root)
        XCTAssertEqual(receiver.leafs.count, dag.leafs.count)
        try receiver.verify()
    }

    // MARK: - Diff Operations

    func testDiffAndApply() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "diff_test_\(UUID().uuidString)"

        // Create first version
        let v1Path = tmpDir + "/v1"
        try fm.createDirectory(atPath: v1Path, withIntermediateDirectories: true)
        try "original".data(using: .utf8)!.write(to: URL(fileURLWithPath: v1Path + "/file.txt"))

        // Create second version (different content)
        let v2Path = tmpDir + "/v2"
        try fm.createDirectory(atPath: v2Path, withIntermediateDirectories: true)
        try "modified".data(using: .utf8)!.write(to: URL(fileURLWithPath: v2Path + "/file.txt"))

        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag1 = try createDag(path: v1Path, timestampRoot: false)
        let dag2 = try createDag(path: v2Path, timestampRoot: false)

        // Different content = different root
        XCTAssertNotEqual(dag1.root, dag2.root)

        let diff = dagDiff(first: dag1, second: dag2)
        XCTAssertGreaterThan(diff.summary.added, 0)
        XCTAssertGreaterThan(diff.summary.removed, 0)
        XCTAssertGreaterThan(diff.summary.total, 0)

        let added = diff.getAddedLeaves()
        let removed = diff.getRemovedLeaves()
        XCTAssertFalse(added.isEmpty)
        XCTAssertFalse(removed.isEmpty)

        let reconstructed = try diff.applyToDAG(dag1)
        XCTAssertEqual(reconstructed.root, dag2.root)
        XCTAssertEqual(reconstructed.leafs.count, dag2.leafs.count)
        XCTAssertEqual(Set(reconstructed.leafs.keys), Set(dag2.leafs.keys))
        try reconstructed.verify()

        let partial = try diff.createPartialDag(fullNewDag: dag2)
        XCTAssertEqual(partial.root, dag2.root)
        XCTAssertFalse(partial.leafs.isEmpty)
        try partial.verify()
    }

    // MARK: - Partial DAG

    func testPartialDagExtractAndVerify() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "partial_test_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try "file1".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/a.txt"))
        try "file2".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/b.txt"))
        try "file3".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/c.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        try dag.verify()

        // Get root leaf to find children
        guard let rootLeaf = dag.leafs[dag.root] else {
            XCTFail("Root leaf not found"); return
        }
        guard !rootLeaf.links.isEmpty else {
            XCTFail("Root has no children"); return
        }

        // Extract partial with first child
        let childHash = rootLeaf.links[0]
        let partial = try dag.getPartial(leafHashes: [childHash], pruneLinks: true)

        // Partial should be smaller
        XCTAssertLessThan(partial.leafs.count, dag.leafs.count)
        XCTAssertTrue(partial.isPartial())
        XCTAssertEqual(partial.root, dag.root)

        // Partial should contain the requested leaf and enough proof data to verify.
        XCTAssertNotNil(partial.leafs[childHash])
        let partialRoot = try XCTUnwrap(partial.leafs[partial.root])
        if rootLeaf.currentLinkCount > 1 {
            XCTAssertNotNil(partialRoot.proofs[childHash])
        }
        try partial.verify()
    }
}