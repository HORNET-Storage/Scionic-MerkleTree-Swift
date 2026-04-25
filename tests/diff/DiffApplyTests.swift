import Foundation
import XCTest
@testable import ScionicMerkleTree

final class DiffApplyTests: XCTestCase {
    func testDiffFromNewLeaves() throws {
        let (oldDag, newDag) = try makeChangedPair()
        let diff = diffFromNewLeaves(originalDag: oldDag, newLeaves: newDag.leafs)

        XCTAssertGreaterThan(diff.summary.added, 0)
        XCTAssertGreaterThanOrEqual(diff.summary.total, diff.summary.added)
    }

    func testGetAddedLeaves() throws {
        let (oldDag, newDag) = try makeChangedPair()
        let diff = dagDiff(first: oldDag, second: newDag)
        let added = diff.getAddedLeaves()

        XCTAssertEqual(added.count, diff.summary.added)
        XCTAssertNotNil(added[newDag.root])
    }

    func testGetRemovedLeaves() throws {
        let root = try makeRoot()
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "remove.txt"), "remove")
        let oldDag = try createDag(path: root)
        try FileManager.default.removeItem(atPath: ParityTestHelpers.join(root, "remove.txt"))
        let newDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: newDag)

        XCTAssertEqual(diff.getRemovedLeaves().count, diff.summary.removed)
        XCTAssertGreaterThan(diff.summary.removed, 0)
    }

    func testApplyToDAG() throws {
        let (oldDag, newDag) = try makeChangedPair()
        let diff = dagDiff(first: oldDag, second: newDag)
        let applied = try diff.applyToDAG(oldDag)

        XCTAssertEqual(applied.root, newDag.root)
        XCTAssertEqual(Set(applied.leafs.keys), Set(newDag.leafs.keys))
        try applied.verify()
    }

    func testCreatePartialDAGFromAdded() throws {
        let (oldDag, newDag) = try makeChangedPair()
        let diff = dagDiff(first: oldDag, second: newDag)
        let partial = try diff.createPartialDag(fullNewDag: newDag)

        XCTAssertEqual(partial.root, newDag.root)
        XCTAssertTrue(partial.isPartial())
        try partial.verify()
    }

    func testCompleteWorkflowNetworkTransmission() throws {
        let (oldDag, newDag) = try makeChangedPair()
        let senderDiff = dagDiff(first: oldDag, second: newDag)
        let partial = try senderDiff.createPartialDag(fullNewDag: newDag)

        let receiver = Dag()
        for packet in partial.getLeafSequence() {
            try receiver.applyAndVerifyTransmissionPacket(packet)
        }

        let receiverDiff = diffFromNewLeaves(originalDag: oldDag, newLeaves: receiver.leafs)
        let applied = try receiverDiff.applyToDAG(oldDag)

        for (hash, senderLeaf) in newDag.leafs {
            let receiverLeaf = try XCTUnwrap(applied.leafs[hash], "receiver missing \(senderLeaf.itemName)")
            XCTAssertEqual(receiverLeaf.itemName, senderLeaf.itemName)
            XCTAssertEqual(receiverLeaf.type, senderLeaf.type)
        }
        XCTAssertEqual(applied.leafs.count, newDag.leafs.count)
        try applied.verify()
    }

    func testApplyToDAGEmptyDiff() throws {
        let root = try makeRoot()
        let oldDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: oldDag)
        let applied = try diff.applyToDAG(oldDag)

        XCTAssertEqual(applied.root, oldDag.root)
        XCTAssertEqual(Set(applied.leafs.keys), Set(oldDag.leafs.keys))
    }

    func testCreatePartialDAGFromAddedNoAdded() throws {
        let root = try makeRoot()
        let dag = try createDag(path: root)
        let diff = dagDiff(first: dag, second: dag)
        XCTAssertThrowsError(try diff.createPartialDag(fullNewDag: dag))
    }

    private func makeChangedPair() throws -> (Dag, Dag) {
        let root = try makeRoot()
        let oldDag = try createDag(path: root)
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "README.md"), "# Changed\n")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "added.txt"), "added")
        return (oldDag, try createDag(path: root))
    }

    private func makeRoot() throws -> String {
        let root = try ParityTestHelpers.makeTempDir("diff_apply")
        try ParityTestHelpers.createBasicDirectory(at: root)
        return root
    }
}
