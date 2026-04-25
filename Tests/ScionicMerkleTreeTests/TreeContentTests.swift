import XCTest
@testable import ScionicMerkleTree

final class TreeContentTests: XCTestCase {

    private func buildContent(_ pairs: [(String, String)]) throws -> (MerkleTree, [String: DataBlock], [DataBlock]) {
        let content = TreeContent()
        for (key, data) in pairs {
            content.addLeaf(key: key, data: data)
        }

        let (tree, leafMap) = try content.build()
        let leaves = tree.keys.map { leafMap[$0]! }
        return (tree, leafMap, leaves)
    }

    func testBuildRejectsEmptyAndSingleLeaf() {
        XCTAssertThrowsError(try TreeContent().build()) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.invalidNumOfDataBlocks)
        }

        let content = TreeContent()
        content.addLeaf(key: "key1", data: "data1")

        XCTAssertThrowsError(try content.build()) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.invalidNumOfDataBlocks)
        }
    }

    func testBuildReturnsMerkleTreeAndLeafMap() throws {
        let (tree, leafMap, leaves) = try buildContent([
            ("key1", "data1"),
            ("key2", "data2"),
            ("key3", "data3"),
        ])

        XCTAssertEqual(tree.numLeaves, 3)
        XCTAssertEqual(tree.proofs.count, 3)
        XCTAssertEqual(tree.keys, ["key1", "key2", "key3"])
        XCTAssertEqual(leafMap.count, 3)
        XCTAssertEqual(leaves.count, 3)
    }

    func testVerifyTreeAndRootAcceptWrapperBuiltLeaves() throws {
        let (tree, _, leaves) = try buildContent([
            ("key1", "data1"),
            ("key2", "data2"),
            ("key3", "data3"),
        ])

        XCTAssertTrue(verifyTree(tree, leaves: leaves))
        XCTAssertTrue(verifyRoot(tree.root, proofs: tree.proofs, leaves: leaves))
    }

    func testVerifyHelpersRejectTamperingWrongProofAndWrongRoot() throws {
        let (tree, _, leaves) = try buildContent([
            ("key1", "data1"),
            ("key2", "data2"),
        ])

        var tamperedLeaves = leaves
        tamperedLeaves[0] = TreeLeaf("modified_data")
        XCTAssertFalse(verifyTree(tree, leaves: tamperedLeaves))

        var wrongProofs = tree.proofs
        wrongProofs.swapAt(0, 1)
        XCTAssertFalse(verifyRoot(tree.root, proofs: wrongProofs, leaves: leaves))

        let wrongRoot = Data(repeating: 0xff, count: tree.root.count)
        XCTAssertFalse(verifyRoot(wrongRoot, proofs: tree.proofs, leaves: leaves))
    }

    func testDuplicateDataStillVerifiesByKeyedProofs() throws {
        let (tree, leafMap, leaves) = try buildContent([
            ("key1", "same_data"),
            ("key2", "same_data"),
        ])

        XCTAssertTrue(verifyTree(tree, leaves: leaves))
        XCTAssertTrue(verifyRoot(tree.root, proofs: tree.proofs, leaves: leaves))

        let (key1Index, key1Exists) = tree.getIndexForKey("key1")
        let (key2Index, key2Exists) = tree.getIndexForKey("key2")
        XCTAssertTrue(key1Exists)
        XCTAssertTrue(key2Exists)

        try tree.verify(dataBlock: leafMap["key1"]!, proof: tree.proofs[key1Index])
        try tree.verify(dataBlock: leafMap["key2"]!, proof: tree.proofs[key2Index])

        XCTAssertThrowsError(try tree.verify(dataBlock: TreeLeaf("modified_data"), proof: tree.proofs[key1Index]))
    }

    func testGetIndexForKeyAfterWrapperBuild() throws {
        let (tree, _, _) = try buildContent([
            ("key1", "data1"),
            ("key2", "data2"),
        ])

        let (index, exists) = tree.getIndexForKey("key1")
        XCTAssertTrue(exists)
        XCTAssertEqual(index, 0)

        let (_, missing) = tree.getIndexForKey("nonexistent")
        XCTAssertFalse(missing)
    }
}
