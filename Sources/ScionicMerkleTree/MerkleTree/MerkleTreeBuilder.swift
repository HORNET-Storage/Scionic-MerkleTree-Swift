// MerkleTreeBuilder.swift — Tree construction and verification
//
// Ported from go-merkletree. Sequential implementation.
// Core functions:
//   - MerkleTree.build(blocks) — builds tree from map of DataBlocks
//   - MerkleTree.verify(dataBlock, proof) — instance verification
//   - MerkleTree.verify(dataBlock, proof, root, config) — standalone verification
//   - MerkleTree.getIndexForKey(key) — look up leaf index by key

import Foundation
import Crypto

// MARK: - Tree Construction

extension MerkleTree {

    /// Builds a new Merkle Tree from a map of key -> DataBlock.
    ///
    /// This mirrors Go's `merkletree.New(config, blocks)`.
    /// Keys are sorted alphabetically; the sorted order determines leaf indices.
    ///
    /// - Parameters:
    ///   - config: Optional configuration. If nil, defaults are used.
    ///   - blocks: Map of key -> DataBlock. Must contain > 1 entry.
    /// - Returns: A built MerkleTree with root, proofs, and leaf hashes.
    public static func build(config: MerkleTreeConfig?, blocks: [String: DataBlock]) throws -> MerkleTree {
        // Sort keys for deterministic ordering
        let sortedKeys = blocks.keys.sorted()
        var sortedBlocks: [DataBlock] = []
        for key in sortedKeys {
            sortedBlocks.append(blocks[key]!)
        }

        guard sortedBlocks.count > 1 else {
            throw MerkleTreeError.invalidNumOfDataBlocks
        }

        let cfg = config ?? MerkleTreeConfig()
        let tree = MerkleTree(config: cfg)
        tree.numLeaves = sortedBlocks.count
        tree.depth = bitLength(UInt(sortedBlocks.count - 1))
        tree.keys = sortedKeys

        // Resolve hash function
        tree.hashFunc = cfg.hashFunc ?? defaultHashFunc

        // Resolve concat function
        tree.concatFunc = cfg.sortSiblingPairs ? concatSortHash : concatHash

        // Generate leaf hashes
        tree.leafHashes = try tree.generateLeaves(sortedBlocks)

        // Build based on mode
        switch cfg.mode {
        case .proofGen:
            try tree.generateProofs()

        case .treeBuild:
            try tree.buildTree()

        case .proofGenAndTreeBuild:
            try tree.buildTree()
            tree.initProofs()
            for i in 0..<tree.nodes.count {
                tree.updateProofs(buffer: tree.nodes[i], bufferLength: tree.nodes[i].count, step: i)
            }
        }

        return tree
    }

    // MARK: - Leaf Generation

    private func generateLeaves(_ blocks: [DataBlock]) throws -> [Data] {
        var leaves = [Data]()
        leaves.reserveCapacity(numLeaves)
        for block in blocks {
            let leaf = try dataBlockToLeaf(block)
            leaves.append(leaf)
        }
        return leaves
    }

    private func dataBlockToLeaf(_ block: DataBlock) throws -> Data {
        let blockBytes = try block.serialize()
        if config.disableLeafHashing {
            return blockBytes
        }
        return try hashFunc(blockBytes)
    }

    // MARK: - Proof Generation (sequential, matches Go's generateProofs)

    private func initProofs() {
        proofs = (0..<numLeaves).map { _ in
            Proof(siblings: [], path: 0)
        }
    }

    private func generateProofs() throws {
        initProofs()
        var buffer = [Data](leafHashes)
        var bufferLength: Int
        (buffer, bufferLength) = fixOddLength(buffer, buffer.count)

        updateProofs(buffer: buffer, bufferLength: numLeaves, step: 0)

        for step in 1..<depth {
            for idx in stride(from: 0, to: bufferLength, by: 2) {
                buffer[idx >> 1] = try hashFunc(concatFunc(buffer[idx], buffer[idx + 1]))
            }
            bufferLength >>= 1
            (buffer, bufferLength) = fixOddLength(buffer, bufferLength)
            updateProofs(buffer: buffer, bufferLength: bufferLength, step: step)
        }

        root = try hashFunc(concatFunc(buffer[0], buffer[1]))
    }

    // MARK: - Tree Building (sequential, matches Go's buildTree)

    private func buildTree() throws {
        // Build leaf map
        leafMap = [:]
        for i in 0..<numLeaves {
            leafMap[leafHashes[i]] = i
        }

        nodes = [[Data]](repeating: [], count: depth)
        nodes[0] = [Data](leafHashes)
        var bufferLength: Int
        (nodes[0], bufferLength) = fixOddLength(nodes[0], numLeaves)

        for i in 0..<(depth - 1) {
            nodes[i + 1] = [Data](repeating: Data(), count: bufferLength >> 1)
            for j in stride(from: 0, to: bufferLength, by: 2) {
                nodes[i + 1][j >> 1] = try hashFunc(concatFunc(nodes[i][j], nodes[i][j + 1]))
            }
            let newLen = nodes[i + 1].count
            (nodes[i + 1], bufferLength) = fixOddLength(nodes[i + 1], newLen)
        }

        root = try hashFunc(concatFunc(
            nodes[depth - 1][0], nodes[depth - 1][1]
        ))
    }

    // MARK: - Proof Update

    private func updateProofs(buffer: [Data], bufferLength: Int, step: Int) {
        let batch = 1 << step
        for i in stride(from: 0, to: bufferLength, by: 2) {
            updateProofPairs(buffer: buffer, idx: i, batch: batch, step: step)
        }
    }

    private func updateProofPairs(buffer: [Data], idx: Int, batch: Int, step: Int) {
        let start = idx * batch
        let end = Swift.min(start + batch, proofs.count)
        if start < end {
            for i in start..<end {
                proofs[i].path += 1 << step
                proofs[i].siblings.append(buffer[idx + 1])
            }
        }
        let start2 = start + batch
        let end2 = Swift.min(start2 + batch, proofs.count)
        if start2 < end2 {
            for i in start2..<end2 {
                proofs[i].siblings.append(buffer[idx])
            }
        }
    }

    // MARK: - Odd Length Fix

    private func fixOddLength(_ buffer: [Data], _ bufferLength: Int) -> ([Data], Int) {
        if bufferLength & 1 == 0 {
            return (buffer, bufferLength)
        }
        var buf = buffer
        let appendNode = buf[bufferLength - 1]
        let newLength = bufferLength + 1
        if buf.count < newLength {
            buf.append(appendNode)
        } else {
            buf[newLength - 1] = appendNode
        }
        return (buf, newLength)
    }

    // MARK: - Key Index Lookup

    /// Retrieves the index for the given key in the sorted key array.
    /// Mirrors Go's `GetIndexForKey`.
    public func getIndexForKey(_ key: String) -> (index: Int, exists: Bool) {
        for (index, storedKey) in keys.enumerated() {
            if storedKey == key {
                return (index, true)
            }
        }
        return (-1, false)
    }
}

// MARK: - Verification

extension MerkleTree {

    /// Verifies a data block against this tree's root using the stored proof.
    public func verify(dataBlock: DataBlock, proof: Proof) throws {
        try MerkleTree.verify(dataBlock: dataBlock, proof: proof, root: root, config: config)
    }

    /// Standalone verification: checks if the data block is valid using the proof and root hash.
    ///
    /// Mirrors Go's top-level `Verify(dataBlock, proof, root, config)` function.
    public static func verify(dataBlock: DataBlock, proof: Proof, root: Data, config: MerkleTreeConfig?) throws {
        let cfg = config ?? MerkleTreeConfig()
        let hash: MerkleHashFunc = cfg.hashFunc ?? defaultHashFunc
        let concat: (Data, Data) -> Data = cfg.sortSiblingPairs ? concatSortHash : concatHash

        // Convert data block to leaf hash
        let blockBytes = try dataBlock.serialize()
        var result: Data
        if cfg.disableLeafHashing {
            result = blockBytes
        } else {
            result = try hash(blockBytes)
        }

        // Traverse the proof path
        var path = proof.path
        for sibling in proof.siblings {
            if path & 1 == 1 {
                result = try hash(concat(result, sibling))
            } else {
                result = try hash(concat(sibling, result))
            }
            path >>= 1
        }

        guard result == root else {
            throw MerkleTreeError.verificationFailed
        }
    }
}

// MARK: - Helpers

/// Returns the number of bits needed to represent the value (equivalent to Go's bits.Len).
private func bitLength(_ value: UInt) -> Int {
    if value == 0 { return 0 }
    return UInt.bitWidth - value.leadingZeroBitCount
}
