import XCTest
@testable import ScionicMerkleTree

/// Simple DataBlock implementation for testing.
struct TestBlock: DataBlock {
    let data: String

    func serialize() throws -> Data {
        return Data(data.utf8)
    }
}

final class MerkleTreeTests: XCTestCase {

    // MARK: - Basic Build + Verify

    func testBuildAndVerifyTwoBlocks() throws {
        let blocks: [String: DataBlock] = [
            "a": TestBlock(data: "block_a"),
            "b": TestBlock(data: "block_b"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        XCTAssertEqual(tree.numLeaves, 2)
        XCTAssertEqual(tree.depth, 1)
        XCTAssertEqual(tree.proofs.count, 2)
        XCTAssertFalse(tree.root.isEmpty)
        XCTAssertEqual(tree.keys, ["a", "b"])

        // Verify each block against its proof
        for i in 0..<tree.numLeaves {
            try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
        }
    }

    func testBuildAndVerifyMultipleBlocks() throws {
        let blocks: [String: DataBlock] = [
            "key1": TestBlock(data: "data1"),
            "key2": TestBlock(data: "data2"),
            "key3": TestBlock(data: "data3"),
            "key4": TestBlock(data: "data4"),
            "key5": TestBlock(data: "data5"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        XCTAssertEqual(tree.numLeaves, 5)
        XCTAssertEqual(tree.proofs.count, 5)
        XCTAssertFalse(tree.root.isEmpty)

        // Verify all blocks
        for i in 0..<tree.numLeaves {
            try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
        }
    }

    // MARK: - Determinism

    func testDeterministicRoot() throws {
        let blocks: [String: DataBlock] = [
            "x": TestBlock(data: "hello"),
            "y": TestBlock(data: "world"),
            "z": TestBlock(data: "test"),
        ]

        let tree1 = try MerkleTree.build(config: nil, blocks: blocks)
        let tree2 = try MerkleTree.build(config: nil, blocks: blocks)

        // Same input → same root
        XCTAssertEqual(tree1.root, tree2.root)

        // Same proofs
        for i in 0..<tree1.proofs.count {
            XCTAssertEqual(tree1.proofs[i].path, tree2.proofs[i].path)
            XCTAssertEqual(tree1.proofs[i].siblings, tree2.proofs[i].siblings)
        }
    }

    func testDifferentDataProducesDifferentRoot() throws {
        let blocks1: [String: DataBlock] = [
            "a": TestBlock(data: "data_a"),
            "b": TestBlock(data: "data_b"),
        ]
        let blocks2: [String: DataBlock] = [
            "a": TestBlock(data: "data_a"),
            "b": TestBlock(data: "data_c"), // different
        ]

        let tree1 = try MerkleTree.build(config: nil, blocks: blocks1)
        let tree2 = try MerkleTree.build(config: nil, blocks: blocks2)

        XCTAssertNotEqual(tree1.root, tree2.root)
    }

    // MARK: - Sorted Keys

    func testKeysAreSorted() throws {
        let blocks: [String: DataBlock] = [
            "zebra": TestBlock(data: "z"),
            "apple": TestBlock(data: "a"),
            "mango": TestBlock(data: "m"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)
        XCTAssertEqual(tree.keys, ["apple", "mango", "zebra"])
    }

    // MARK: - Key Index Lookup

    func testGetIndexForKey() throws {
        let blocks: [String: DataBlock] = [
            "b": TestBlock(data: "2"),
            "a": TestBlock(data: "1"),
            "c": TestBlock(data: "3"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        let (idxA, existsA) = tree.getIndexForKey("a")
        XCTAssertTrue(existsA)
        XCTAssertEqual(idxA, 0)

        let (idxB, existsB) = tree.getIndexForKey("b")
        XCTAssertTrue(existsB)
        XCTAssertEqual(idxB, 1)

        let (idxC, existsC) = tree.getIndexForKey("c")
        XCTAssertTrue(existsC)
        XCTAssertEqual(idxC, 2)

        let (_, existsX) = tree.getIndexForKey("x")
        XCTAssertFalse(existsX)
    }

    // MARK: - Standalone Verification

    func testStandaloneVerify() throws {
        let blocks: [String: DataBlock] = [
            "k1": TestBlock(data: "v1"),
            "k2": TestBlock(data: "v2"),
            "k3": TestBlock(data: "v3"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        // Verify using standalone static method with explicit root
        for i in 0..<tree.numLeaves {
            try MerkleTree.verify(
                dataBlock: blocks[tree.keys[i]]!,
                proof: tree.proofs[i],
                root: tree.root,
                config: nil
            )
        }
    }

    func testVerifyFailsWithWrongData() throws {
        let blocks: [String: DataBlock] = [
            "a": TestBlock(data: "original"),
            "b": TestBlock(data: "data"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        // Use wrong data block with proof for "a"
        let wrongBlock = TestBlock(data: "tampered")
        XCTAssertThrowsError(try tree.verify(dataBlock: wrongBlock, proof: tree.proofs[0])) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.verificationFailed)
        }
    }

    func testVerifyFailsWithWrongRoot() throws {
        let blocks: [String: DataBlock] = [
            "a": TestBlock(data: "data_a"),
            "b": TestBlock(data: "data_b"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)
        let fakeRoot = Data(repeating: 0xff, count: 32)

        XCTAssertThrowsError(try MerkleTree.verify(
            dataBlock: blocks["a"]!,
            proof: tree.proofs[0],
            root: fakeRoot,
            config: nil
        )) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.verificationFailed)
        }
    }

    // MARK: - Error Cases

    func testBuildFailsWithOneBlock() {
        let blocks: [String: DataBlock] = [
            "only": TestBlock(data: "single"),
        ]

        XCTAssertThrowsError(try MerkleTree.build(config: nil, blocks: blocks)) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.invalidNumOfDataBlocks)
        }
    }

    func testBuildFailsWithEmptyBlocks() {
        let blocks: [String: DataBlock] = [:]

        XCTAssertThrowsError(try MerkleTree.build(config: nil, blocks: blocks)) { error in
            XCTAssertEqual(error as? MerkleTreeError, MerkleTreeError.invalidNumOfDataBlocks)
        }
    }

    // MARK: - Odd Number of Leaves

    func testOddNumberOfLeaves() throws {
        let blocks: [String: DataBlock] = [
            "a": TestBlock(data: "1"),
            "b": TestBlock(data: "2"),
            "c": TestBlock(data: "3"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)
        XCTAssertEqual(tree.numLeaves, 3)

        // All proofs should verify
        for i in 0..<tree.numLeaves {
            try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
        }
    }

    // MARK: - Large Number of Blocks

    func testLargeTree() throws {
        var blocks: [String: DataBlock] = [:]
        for i in 0..<100 {
            blocks["key\(String(format: "%03d", i))"] = TestBlock(data: "data_\(i)")
        }

        let tree = try MerkleTree.build(config: nil, blocks: blocks)
        XCTAssertEqual(tree.numLeaves, 100)
        XCTAssertFalse(tree.root.isEmpty)

        // Verify all proofs
        for i in 0..<tree.numLeaves {
            try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
        }
    }

    // MARK: - Power of Two Leaves

    func testPowerOfTwoLeaves() throws {
        // 2, 4, 8 leaves — no odd-length fixup needed
        for count in [2, 4, 8] {
            var blocks: [String: DataBlock] = [:]
            for i in 0..<count {
                blocks["k\(i)"] = TestBlock(data: "v\(i)")
            }

            let tree = try MerkleTree.build(config: nil, blocks: blocks)
            XCTAssertEqual(tree.numLeaves, count)

            for i in 0..<tree.numLeaves {
                try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
            }
        }
    }

    // MARK: - Simulating DAG Usage (CID-like string blocks)

    func testWithCIDLikeBlocks() throws {
        // This simulates how the DAG package uses merkle trees — keys and values are CID strings
        let blocks: [String: DataBlock] = [
            "bafy...abc1": TestBlock(data: "bafy...abc1"),
            "bafy...abc2": TestBlock(data: "bafy...abc2"),
            "bafy...abc3": TestBlock(data: "bafy...abc3"),
        ]

        let tree = try MerkleTree.build(config: nil, blocks: blocks)

        XCTAssertEqual(tree.numLeaves, 3)
        XCTAssertFalse(tree.root.isEmpty)

        // Verify all
        for i in 0..<tree.numLeaves {
            try tree.verify(dataBlock: blocks[tree.keys[i]]!, proof: tree.proofs[i])
        }

        // Test key index lookup
        let (idx, exists) = tree.getIndexForKey("bafy...abc2")
        XCTAssertTrue(exists)
        XCTAssertGreaterThanOrEqual(idx, 0)
    }

    // MARK: - Parallel Build Parity

    func testParallelProofAndTreeBuildMatchesSequential() throws {
        let blocks = makeParallelBlocks(count: 257)
        let sequentialConfig = MerkleTreeConfig(mode: .proofGenAndTreeBuild)
        let parallelConfig = MerkleTreeConfig(
            mode: .proofGenAndTreeBuild,
            runInParallel: true,
            numRoutines: 4
        )

        let sequential = try MerkleTree.build(config: sequentialConfig, blocks: blocks)
        let parallel = try MerkleTree.build(config: parallelConfig, blocks: blocks)

        XCTAssertEqual(parallel.root, sequential.root)
        XCTAssertEqual(parallel.keys, sequential.keys)
        XCTAssertEqual(parallel.leafHashes, sequential.leafHashes)
        XCTAssertEqual(parallel.nodes, sequential.nodes)
        assertProofsEqual(parallel.proofs, sequential.proofs)

        for i in 0..<parallel.numLeaves {
            try parallel.verify(dataBlock: blocks[parallel.keys[i]]!, proof: parallel.proofs[i])
        }
    }

    func testParallelProofGenerationMatchesSequential() throws {
        let blocks = makeParallelBlocks(count: 129)
        let sequential = try MerkleTree.build(config: MerkleTreeConfig(mode: .proofGen), blocks: blocks)
        let parallel = try MerkleTree.build(
            config: MerkleTreeConfig(mode: .proofGen, runInParallel: true, numRoutines: 3),
            blocks: blocks
        )

        XCTAssertEqual(parallel.root, sequential.root)
        XCTAssertEqual(parallel.keys, sequential.keys)
        XCTAssertEqual(parallel.leafHashes, sequential.leafHashes)
        assertProofsEqual(parallel.proofs, sequential.proofs)

        for i in 0..<parallel.numLeaves {
            try parallel.verify(dataBlock: blocks[parallel.keys[i]]!, proof: parallel.proofs[i])
        }
    }

    func testParallelProofUpdatesMatchSequentialAcrossWorkerCounts() throws {
        let blocks = makeParallelBlocks(count: 511)
        let sequentialProofOnly = try MerkleTree.build(config: MerkleTreeConfig(mode: .proofGen), blocks: blocks)
        let sequentialWithTree = try MerkleTree.build(config: MerkleTreeConfig(mode: .proofGenAndTreeBuild), blocks: blocks)

        for workers in [2, 3, 5, 8] {
            let parallelProofOnly = try MerkleTree.build(
                config: MerkleTreeConfig(mode: .proofGen, runInParallel: true, numRoutines: workers),
                blocks: blocks
            )
            let parallelWithTree = try MerkleTree.build(
                config: MerkleTreeConfig(mode: .proofGenAndTreeBuild, runInParallel: true, numRoutines: workers),
                blocks: blocks
            )

            XCTAssertEqual(parallelProofOnly.root, sequentialProofOnly.root, "proofGen root changed with workers=\(workers)")
            XCTAssertEqual(parallelWithTree.root, sequentialWithTree.root, "proofGenAndTreeBuild root changed with workers=\(workers)")
            assertProofsEqual(parallelProofOnly.proofs, sequentialProofOnly.proofs)
            assertProofsEqual(parallelWithTree.proofs, sequentialWithTree.proofs)
            XCTAssertEqual(parallelWithTree.nodes, sequentialWithTree.nodes)
        }
    }

    private func makeParallelBlocks(count: Int) -> [String: DataBlock] {
        var blocks: [String: DataBlock] = [:]
        for i in 0..<count {
            let key = "parallel_\(String(format: "%04d", i))"
            blocks[key] = TestBlock(data: "parallel_data_\(i)_\(i * 31)")
        }
        return blocks
    }

    private func assertProofsEqual(_ lhs: [Proof], _ rhs: [Proof], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (left, right) in zip(lhs, rhs) {
            XCTAssertEqual(left.path, right.path, file: file, line: line)
            XCTAssertEqual(left.siblings, right.siblings, file: file, line: line)
        }
    }
}