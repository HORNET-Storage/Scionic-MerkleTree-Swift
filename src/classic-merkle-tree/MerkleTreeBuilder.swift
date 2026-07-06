// MerkleTreeBuilder.swift — Tree construction and verification
//
// Ported from go-merkletree with deterministic sequential and parallel build paths.
// Core functions:
//   - MerkleTree.build(blocks) — builds tree from map of DataBlocks
//   - MerkleTree.verify(dataBlock, proof) — instance verification
//   - MerkleTree.verify(dataBlock, proof, root, config) — standalone verification
//   - MerkleTree.getIndexForKey(key) — look up leaf index by key

import Foundation
import Crypto

private final class ParallelMerkleState<Element> {
    private var values: [Element?]
    private var firstError: Error?
    private let lock = NSLock()

    init(count: Int) {
        values = Array<Element?>(repeating: nil, count: count)
    }

    func set(_ value: Element, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil {
            values[index] = value
        }
    }

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil {
            firstError = error
        }
    }

    func result() throws -> [Element] {
        lock.lock(); defer { lock.unlock() }
        if let firstError = firstError {
            throw firstError
        }

        var result: [Element] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let value = value else {
                throw MerkleTreeError.serializationFailed("parallel merkle worker did not produce a result")
            }
            result.append(value)
        }
        return result
    }
}

private final class ProofAccumulator: @unchecked Sendable {
    private var siblings: [Data] = []
    private var path: UInt32 = 0

    func appendLeftSibling(_ sibling: Data, step: Int) {
        path += UInt32(1 << step)
        siblings.append(sibling)
    }

    func appendRightSibling(_ sibling: Data) {
        siblings.append(sibling)
    }

    func proof() -> Proof {
        Proof(siblings: siblings, path: path)
    }
}

private final class ParallelProofState: @unchecked Sendable {
    private let proofs: [ProofAccumulator]

    init(count: Int) {
        proofs = (0..<count).map { _ in ProofAccumulator() }
    }

    func updatePair(buffer: [Data], idx: Int, batch: Int, step: Int) {
        let start = idx * batch
        let end = Swift.min(start + batch, proofs.count)
        if start < end {
            for i in start..<end {
                proofs[i].appendLeftSibling(buffer[idx + 1], step: step)
            }
        }

        let start2 = start + batch
        let end2 = Swift.min(start2 + batch, proofs.count)
        if start2 < end2 {
            for i in start2..<end2 {
                proofs[i].appendRightSibling(buffer[idx])
            }
        }
    }

    func result() -> [Proof] {
        proofs.map { $0.proof() }
    }
}

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
        tree.leafHashes = try tree.shouldRunParallel(workItems: sortedBlocks.count)
            ? tree.generateLeavesInParallel(sortedBlocks)
            : tree.generateLeaves(sortedBlocks)

        // Build based on mode
        switch cfg.mode {
        case .proofGen:
            try tree.generateProofs()

        case .treeBuild:
            try tree.buildTree()

        case .proofGenAndTreeBuild:
            try tree.buildTree()
            if tree.config.runInParallel {
                let proofState = ParallelProofState(count: tree.numLeaves)
                for i in 0..<tree.nodes.count {
                    tree.updateProofsInParallel(buffer: tree.nodes[i], bufferLength: tree.nodes[i].count, step: i, state: proofState)
                }
                tree.proofs = proofState.result()
            } else {
                tree.initProofs()
                for i in 0..<tree.nodes.count {
                    tree.updateProofs(buffer: tree.nodes[i], bufferLength: tree.nodes[i].count, step: i)
                }
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

    private func generateLeavesInParallel(_ blocks: [DataBlock]) throws -> [Data] {
        let workers = workerCount(for: blocks.count)
        guard workers > 1 else {
            return try generateLeaves(blocks)
        }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let state = ParallelMerkleState<Data>(count: blocks.count)

        for worker in 0..<workers {
            group.enter()
            queue.async {
                defer { group.leave() }

                var index = worker
                while index < blocks.count {
                    do {
                        let leaf = try self.dataBlockToLeaf(blocks[index])
                        state.set(leaf, at: index)
                    } catch {
                        state.record(error)
                        return
                    }
                    index += workers
                }
            }
        }

        group.wait()
        return try state.result()
    }

    private func computeParentLevelInParallel(buffer: [Data], bufferLength: Int) throws -> [Data] {
        let parentCount = bufferLength >> 1
        let workers = workerCount(for: parentCount)
        guard parentCount > 0 else { return [] }
        guard workers > 1 else {
            var parents = [Data](repeating: Data(), count: parentCount)
            for pairIndex in 0..<parentCount {
                let idx = pairIndex << 1
                parents[pairIndex] = try hashFunc(concatFunc(buffer[idx], buffer[idx + 1]))
            }
            return parents
        }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let state = ParallelMerkleState<Data>(count: parentCount)

        for worker in 0..<workers {
            group.enter()
            queue.async {
                defer { group.leave() }

                var pairIndex = worker
                while pairIndex < parentCount {
                    let idx = pairIndex << 1
                    do {
                        let parent = try self.hashFunc(self.concatFunc(buffer[idx], buffer[idx + 1]))
                        state.set(parent, at: pairIndex)
                    } catch {
                        state.record(error)
                        return
                    }
                    pairIndex += workers
                }
            }
        }

        group.wait()
        return try state.result()
    }

    private func workerCount(for workItems: Int) -> Int {
        guard workItems > 0 else { return 0 }
        let requested = config.numRoutines <= 0 ? ProcessInfo.processInfo.processorCount : config.numRoutines
        return max(1, min(requested, workItems))
    }

    private func shouldRunParallel(workItems: Int) -> Bool {
        config.runInParallel && workerCount(for: workItems) > 1
    }

    private func dataBlockToLeaf(_ block: DataBlock) throws -> Data {
        let blockBytes = try block.serialize()
        if config.disableLeafHashing {
            return blockBytes
        }
        return try hashFunc(blockBytes)
    }

    // MARK: - Proof Generation

    private func initProofs() {
        proofs = (0..<numLeaves).map { _ in
            Proof(siblings: [], path: 0)
        }
    }

    private func generateProofs() throws {
        var buffer = [Data](leafHashes)
        var bufferLength: Int
        (buffer, bufferLength) = fixOddLength(buffer, buffer.count)

        if config.runInParallel {
            try generateProofsInParallel(buffer: buffer, bufferLength: bufferLength)
            return
        }

        initProofs()
        updateProofs(buffer: buffer, bufferLength: numLeaves, step: 0)

        for step in 1..<depth {
            let parentCount = bufferLength >> 1
            for idx in stride(from: 0, to: bufferLength, by: 2) {
                buffer[idx >> 1] = try hashFunc(concatFunc(buffer[idx], buffer[idx + 1]))
            }
            bufferLength = parentCount
            (buffer, bufferLength) = fixOddLength(buffer, bufferLength)
            updateProofs(buffer: buffer, bufferLength: bufferLength, step: step)
        }

        root = try hashFunc(concatFunc(buffer[0], buffer[1]))
    }

    private func generateProofsInParallel(buffer: [Data], bufferLength: Int) throws {
        let proofState = ParallelProofState(count: numLeaves)
        var workingBuffer = buffer
        var workingLength = bufferLength

        updateProofsInParallel(buffer: workingBuffer, bufferLength: numLeaves, step: 0, state: proofState)

        for step in 1..<depth {
            let parentCount = workingLength >> 1
            if shouldRunParallel(workItems: parentCount) {
                let parents = try computeParentLevelInParallel(buffer: workingBuffer, bufferLength: workingLength)
                for (idx, parent) in parents.enumerated() {
                    workingBuffer[idx] = parent
                }
            } else {
                for idx in stride(from: 0, to: workingLength, by: 2) {
                    workingBuffer[idx >> 1] = try hashFunc(concatFunc(workingBuffer[idx], workingBuffer[idx + 1]))
                }
            }

            workingLength = parentCount
            (workingBuffer, workingLength) = fixOddLength(workingBuffer, workingLength)
            updateProofsInParallel(buffer: workingBuffer, bufferLength: workingLength, step: step, state: proofState)
        }

        root = try hashFunc(concatFunc(workingBuffer[0], workingBuffer[1]))
        proofs = proofState.result()
    }

    // MARK: - Tree Building

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
            let parentCount = bufferLength >> 1
            if shouldRunParallel(workItems: parentCount) {
                nodes[i + 1] = try computeParentLevelInParallel(buffer: nodes[i], bufferLength: bufferLength)
            } else {
                nodes[i + 1] = [Data](repeating: Data(), count: parentCount)
                for j in stride(from: 0, to: bufferLength, by: 2) {
                    nodes[i + 1][j >> 1] = try hashFunc(concatFunc(nodes[i][j], nodes[i][j + 1]))
                }
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

    private func updateProofsInParallel(buffer: [Data], bufferLength: Int, step: Int, state: ParallelProofState) {
        let batch = 1 << step
        let pairCount = (bufferLength + 1) >> 1
        let workers = workerCount(for: pairCount)
        guard workers > 1 else {
            for pairIndex in 0..<pairCount {
                state.updatePair(buffer: buffer, idx: pairIndex << 1, batch: batch, step: step)
            }
            return
        }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for worker in 0..<workers {
            group.enter()
            queue.async {
                defer { group.leave() }

                var pairIndex = worker
                while pairIndex < pairCount {
                    state.updatePair(buffer: buffer, idx: pairIndex << 1, batch: batch, step: step)
                    pairIndex += workers
                }
            }
        }

        group.wait()
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
        // keys is sorted during construction, so binary search.
        var lo = 0
        var hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        if lo < keys.count && keys[lo] == key { return (lo, true) }
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
