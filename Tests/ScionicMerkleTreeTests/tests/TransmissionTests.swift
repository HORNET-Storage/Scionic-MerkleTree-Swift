import XCTest
@testable import ScionicMerkleTree

final class TransmissionTests: XCTestCase {

    func testBatchedTransmissionApplyAndVerifyRebuildsDag() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }
        setBatchSize(1)
        defer { setDefaultBatchSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "batched_transmission_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input + "/sub", withIntermediateDirectories: true)
        try "alpha".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/a.txt"))
        try "bravo".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/b.txt"))
        try "charlie".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/sub/c.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        let batches = dag.getBatchedLeafSequence()
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.first?.getRootLeaf()?.hash, dag.root)

        let receiver = Dag()
        for batch in batches {
            try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
        }

        XCTAssertEqual(receiver.root, dag.root)
        XCTAssertEqual(receiver.leafs.count, dag.leafs.count)
        try receiver.verify()
    }

    func testBatchedTransmissionRejectsMissingRelationship() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }
        setBatchSize(1)
        defer { setDefaultBatchSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "batched_relationship_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try "alpha".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/a.txt"))
        try "bravo".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/b.txt"))
        defer { try? fm.removeItem(atPath: tmpDir) }

        let dag = try createDag(path: input, timestampRoot: false)
        var badBatch = try XCTUnwrap(dag.getBatchedLeafSequence().first)
        let firstLeaf = try XCTUnwrap(badBatch.leaves.first)
        badBatch.relationships.removeValue(forKey: firstLeaf.hash)

        XCTAssertThrowsError(try Dag().verifyBatchedTransmissionPacket(badBatch))
    }
}
