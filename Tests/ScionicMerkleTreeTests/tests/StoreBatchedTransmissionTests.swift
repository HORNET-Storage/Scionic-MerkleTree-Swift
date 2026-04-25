import Foundation
import XCTest
@testable import ScionicMerkleTree

final class StoreBatchedTransmissionTests: XCTestCase {
    func testDagStoreAddBatchedTransmissionPacket() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let batches = dag.getBatchedLeafSequence()
            XCTAssertFalse(batches.isEmpty, fixture.name)

            let receiver = DagStore.empty()
            for batch in batches {
                try receiver.addBatchedTransmissionPacket(batch)
            }

            try receiver.verifyStreaming()
            let received = try receiver.toDag()
            XCTAssertEqual(received.root, dag.root, fixture.name)
            XCTAssertEqual(received.leafs.count, dag.leafs.count, fixture.name)
            XCTAssertEqual(Set(received.leafs.keys), Set(dag.leafs.keys), fixture.name)
        }
    }

    func testDagStoreAddBatchedPacketEmptyPacket() throws {
        let store = DagStore.empty()

        XCTAssertNoThrow(try store.addBatchedTransmissionPacket(nil as BatchedTransmissionPacket?))
        XCTAssertNoThrow(try store.addBatchedTransmissionPacket(BatchedTransmissionPacket()))
        XCTAssertEqual(store.root, "")
        XCTAssertEqual(try store.countLeavesStreaming(), 0)
    }
}
