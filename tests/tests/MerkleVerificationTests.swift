import Foundation
import XCTest
@testable import ScionicMerkleTree

final class MerkleVerificationTests: XCTestCase {
    func testMerkleRootVerificationDetectsTampering() throws {
        let root = try ParityTestHelpers.makeTempDir("merkle_tamper")
        try ParityTestHelpers.createFlatFiles(at: root, count: 4)
        let dag = try createDag(path: root)
        let tampered = ParityTestHelpers.clonedDag(dag)
        let rootLeaf = try XCTUnwrap(tampered.leafs[tampered.root])
        rootLeaf.classicMerkleRoot = Data(repeating: 0xff, count: rootLeaf.classicMerkleRoot.count)

        XCTAssertThrowsError(try tampered.verify())
    }

    func testPartialDagMerkleVerification() throws {
        let root = try ParityTestHelpers.makeTempDir("merkle_partial")
        try ParityTestHelpers.createFlatFiles(at: root, count: 5)
        let dag = try createDag(path: root)
        let target = try XCTUnwrap(dag.leafs[dag.root]?.links.first)
        let partial = try dag.getPartial(leafHashes: [target], pruneLinks: true)

        try partial.verify()
        let partialRoot = try XCTUnwrap(partial.leafs[partial.root])
        let proof = try XCTUnwrap(partialRoot.proofs[target])
        try partialRoot.verifyBranch(proof)
    }
}
