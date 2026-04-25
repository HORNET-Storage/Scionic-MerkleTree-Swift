import Foundation
import XCTest
@testable import ScionicMerkleTree

final class IntegrationTests: XCTestCase {
    func testCompleteWorkflowDeepHierarchy() throws {
        let root = try ParityTestHelpers.makeTempDir("integration_deep")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        try ParityTestHelpers.writeData(
            ParityTestHelpers.join(root, "level2", "nested", "large.bin"),
            ParityTestHelpers.deterministicData(size: defaultChunkSize + 512)
        )

        let dag = try createDag(path: root)
        try dag.verify()

        try dag.calculateLabels()
        let firstRange = try dag.getHashesByLabelRange(start: 1, end: min(3, dag.labels.count))
        XCTAssertFalse(firstRange.isEmpty)

        let decoded = try Dag.fromCBOR(dag.toCBOR())
        XCTAssertEqual(decoded.root, dag.root)
        try decoded.verify()

        let store = DagStore(dag)
        try store.verify()
        let storedDag = try store.toDag()
        XCTAssertEqual(storedDag.root, dag.root)

        let target = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file))
        let partial = try dag.getPartial(leafHashes: [target.hash], pruneLinks: true)
        XCTAssertTrue(partial.isPartial())
        try partial.verify()

        let receiver = Dag()
        for packet in dag.getLeafSequence() {
            try receiver.applyAndVerifyTransmissionPacket(packet)
        }
        XCTAssertEqual(receiver.root, dag.root)
        XCTAssertEqual(receiver.leafs.count, dag.leafs.count)
        try receiver.verify()
    }
}
