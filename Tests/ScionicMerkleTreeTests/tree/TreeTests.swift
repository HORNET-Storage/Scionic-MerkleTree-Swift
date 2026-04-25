import Foundation
import XCTest
@testable import ScionicMerkleTree

final class TreeParityTests: XCTestCase {
    func testBasicTreeOperations() throws {
        let blocks = makeBlocks(["a", "b", "c", "d"])
        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        XCTAssertEqual(tree.numLeaves, 4)
        XCTAssertEqual(tree.proofs.count, 4)
        XCTAssertEqual(tree.keys, ["a", "b", "c", "d"])
        XCTAssertFalse(tree.root.isEmpty)
    }

    func testProofVerification() throws {
        let blocks = makeBlocks(["a", "b", "c"])
        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        for index in 0..<tree.numLeaves {
            let key = tree.keys[index]
            try MerkleTree.verify(dataBlock: blocks[key]!, proof: tree.proofs[index], root: tree.root, config: nil)
            try tree.verify(dataBlock: blocks[key]!, proof: tree.proofs[index])
        }
    }

    func testKeyFeatures() throws {
        let blocks = makeBlocks(["z", "a", "m"])
        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        XCTAssertEqual(tree.keys, ["a", "m", "z"])
        let (index, exists) = tree.getIndexForKey("m")
        XCTAssertTrue(exists)
        XCTAssertEqual(tree.keys[index], "m")
        let (_, missing) = tree.getIndexForKey("missing")
        XCTAssertFalse(missing)
    }

    func testEdgeCases() throws {
        let oddBlocks = makeBlocks(["a", "b", "c", "d", "e"])
        let oddTree = try MerkleTree.build(config: nil, blocks: oddBlocks)
        XCTAssertEqual(oddTree.numLeaves, 5)
        for index in 0..<oddTree.numLeaves {
            try oddTree.verify(dataBlock: oddBlocks[oddTree.keys[index]]!, proof: oddTree.proofs[index])
        }

        var manyBlocks: [String: DataBlock] = [:]
        for index in 0..<32 {
            manyBlocks[String(format: "key%02d", index)] = TestBlock(data: "data\(index)")
        }
        let manyTree = try MerkleTree.build(config: nil, blocks: manyBlocks)
        XCTAssertEqual(manyTree.numLeaves, 32)
        XCTAssertFalse(manyTree.root.isEmpty)
    }

    func testErrorCases() throws {
        XCTAssertThrowsError(try MerkleTree.build(config: nil, blocks: [:]))
        XCTAssertThrowsError(try MerkleTree.build(config: nil, blocks: ["only": TestBlock(data: "single")]))

        let blocks = makeBlocks(["a", "b"])
        let tree = try MerkleTree.build(config: nil, blocks: blocks)
        XCTAssertThrowsError(try MerkleTree.verify(
            dataBlock: TestBlock(data: "tampered"),
            proof: tree.proofs[0],
            root: tree.root,
            config: nil
        ))
    }

    private func makeBlocks(_ keys: [String]) -> [String: DataBlock] {
        var blocks: [String: DataBlock] = [:]
        for key in keys {
            blocks[key] = TestBlock(data: "data_\(key)")
        }
        return blocks
    }
}
