import Foundation
import XCTest
@testable import ScionicMerkleTree

final class PartialMergeTests: XCTestCase {
    func testPartialDAGMergeBehavior() throws {
        let root = try ParityTestHelpers.makeTempDir("partial_merge")
        try ParityTestHelpers.createFlatFiles(at: root, count: 5)
        let dag = try createDag(path: root)
        let targets = Array(try XCTUnwrap(dag.leafs[dag.root]?.links.prefix(2)))

        let first = try dag.getPartial(leafHashes: [targets[0]], pruneLinks: true)
        let second = try dag.getPartial(leafHashes: [targets[1]], pruneLinks: true)
        let combined = try dag.getPartial(leafHashes: targets, pruneLinks: true)
        let combinedRoot = try XCTUnwrap(combined.leafs[combined.root])

        XCTAssertNotNil(first.leafs[targets[0]])
        XCTAssertNotNil(second.leafs[targets[1]])
        XCTAssertNotNil(combined.leafs[targets[0]])
        XCTAssertNotNil(combined.leafs[targets[1]])
        XCTAssertEqual(Set(combinedRoot.links), Set(targets))
        XCTAssertTrue(combined.isPartial())
        try combined.verify()
    }

    func testPartialDAGProofCompleteness() throws {
        let root = try ParityTestHelpers.makeTempDir("partial_proofs")
        try ParityTestHelpers.createFlatFiles(at: root, count: 6)
        let dag = try createDag(path: root)
        let requested = Array(try XCTUnwrap(dag.leafs[dag.root]?.links.prefix(3)))

        let partial = try dag.getPartial(leafHashes: requested, pruneLinks: true)
        let partialRoot = try XCTUnwrap(partial.leafs[partial.root])

        XCTAssertEqual(partialRoot.links, requested)
        for hash in requested {
            let proof = try XCTUnwrap(partialRoot.proofs[hash])
            try partialRoot.verifyBranch(proof)
        }
        try partial.verify()
    }
}
