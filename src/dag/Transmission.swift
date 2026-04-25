// Transmission.swift — Transmission packets and LeafSync protocol
//
// Ported from dag/transmission.go.
// Generates ordered transmission packets (BFS) with Merkle proofs for independent verification.

import Foundation

// MARK: - Leaf Sequence (Transmission Packets)

extension Dag {

    /// Returns leaves in BFS transmission order with parent refs and Merkle proofs.
    ///
    /// Mirrors Go's `GetLeafSequence`. Root comes first, then children in sorted order.
    /// Each packet includes proofs so the receiver can verify each leaf independently.
    public func getLeafSequence() -> [TransmissionPacket] {
        if isPartial() {
            return getPartialLeafSequence()
        }

        var sequence: [TransmissionPacket] = []
        var visited = Set<String>()

        guard let rootLeaf = leafs[root] else { return sequence }

        // Root packet
        sequence.append(TransmissionPacket(leaf: rootLeaf.clone(), parentHash: ""))
        visited.insert(root)

        // BFS traversal
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let currentLeaf = leafs[current] else { continue }

            let sortedLinks = currentLeaf.links.sorted()

            for childHash in sortedLinks {
                if !visited.contains(childHash) {
                    guard let childLeaf = leafs[childHash] else { continue }

                    // Build verification branch for proofs
                    let branch = try? buildVerificationBranch(childLeaf)

                    let leafClone = childLeaf.clone()
                    var packet = TransmissionPacket(leaf: leafClone, parentHash: current)

                    // Extract proofs from branch path nodes
                    if let branch = branch {
                        for pathNode in branch.path {
                            for (k, v) in pathNode.proofs {
                                packet.proofs[k] = v
                            }
                        }
                    }

                    sequence.append(packet)
                    visited.insert(childHash)
                    queue.append(childHash)
                }
            }
        }

        return sequence
    }

    /// Specialized leaf sequence for partial DAGs (proofs already embedded).
    private func getPartialLeafSequence() -> [TransmissionPacket] {
        var sequence: [TransmissionPacket] = []
        var visited = Set<String>()

        guard let rootLeaf = leafs[root] else { return sequence }

        sequence.append(TransmissionPacket(leaf: rootLeaf.clone(), parentHash: ""))
        visited.insert(root)

        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let currentLeaf = leafs[current] else { continue }

            let sortedLinks = currentLeaf.links.sorted()

            for childHash in sortedLinks {
                if !visited.contains(childHash) {
                    guard let childLeaf = leafs[childHash] else { continue }

                    let leafClone = childLeaf.clone()
                    var packet = TransmissionPacket(leaf: leafClone, parentHash: current)

                    // Extract proof from parent's stored proofs
                    if let proof = currentLeaf.proofs[childHash] {
                        packet.proofs[childHash] = proof
                    }

                    sequence.append(packet)
                    visited.insert(childHash)
                    queue.append(childHash)
                }
            }
        }

        return sequence
    }
}

// MARK: - Verify / Apply Transmission Packets

extension Dag {

    /// Verifies a single transmission packet.
    ///
    /// Root packets verify via `verifyRootLeaf`, others via `verifyLeaf` + Merkle proof.
    public func verifyTransmissionPacket(_ packet: TransmissionPacket) throws {
        if packet.parentHash.isEmpty {
            // Root packet — verify as root leaf (pass nil dag for standalone verification)
            try packet.leaf.verifyRootLeaf(dag: self)
        } else {
            try packet.leaf.verifyLeaf()

            // If parent exists and has multiple children, verify Merkle proof
            if let parent = leafs[packet.parentHash], parent.links.count > 1 {
                guard let proof = packet.proofs[packet.leaf.hash] else {
                    throw DagError.brokenDag("missing merkle proof for \(packet.leaf.hash)")
                }
                try parent.verifyBranch(proof)
            }
        }
    }

    /// Applies a transmission packet to this DAG.
    ///
    /// Adds the leaf, establishes parent link, stores proofs, and records the root packet.
    public func applyTransmissionPacket(_ packet: TransmissionPacket) {
        leafs[packet.leaf.hash] = packet.leaf

        if packet.parentHash.isEmpty {
            root = packet.leaf.hash
        } else if let parent = leafs[packet.parentHash] {
            if !parent.hasLink(packet.leaf.hash) {
                parent.addLink(packet.leaf.hash)
            }
        }

        // Apply proofs to parent leaves
        for (leafHash, proof) in packet.proofs {
            for (_, leaf) in leafs {
                if leaf.hasLink(leafHash) {
                    leaf.proofs[leafHash] = proof
                    break
                }
            }
        }
    }

    /// Verifies then applies a transmission packet.
    public func applyAndVerifyTransmissionPacket(_ packet: TransmissionPacket) throws {
        try verifyTransmissionPacket(packet)
        applyTransmissionPacket(packet)
    }

    /// Removes all content from leaves (for transmission without file data).
    public func removeAllContent() {
        for (_, leaf) in leafs {
            leaf.content = nil
        }
    }
}

// MARK: - Batched Transmission

extension Dag {

    /// Groups leaves into size-limited batches for efficient transmission.
    ///
    /// Mirrors Go's `GetBatchedLeafSequence`. Maintains BFS order.
    /// If batchSize <= 0, each leaf becomes its own batch.
    public func getBatchedLeafSequence() -> [BatchedTransmissionPacket] {
        // If batching disabled, wrap each individual packet
        if batchSize <= 0 {
            let packets = getLeafSequence()
            return packets.enumerated().map { (i, packet) in
                BatchedTransmissionPacket(
                    leaves: [packet.leaf],
                    relationships: [packet.leaf.hash: packet.parentHash],
                    packetIndex: i,
                    totalPackets: packets.count
                )
            }
        }

        var batches: [BatchedTransmissionPacket] = []
        var visited = Set<String>()

        guard let rootLeaf = leafs[root] else { return batches }

        // Start first batch with root
        var currentBatch = BatchedTransmissionPacket()
        var currentBatchSize = 0

        let rootClone = rootLeaf.clone()
        currentBatch.leaves.append(rootClone)
        currentBatch.relationships[rootClone.hash] = ""
        currentBatchSize += rootClone.estimateSize()
        visited.insert(root)

        var parentsInBatch = Set<String>([root])

        // BFS traversal
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let currentLeaf = leafs[current] else { continue }

            let sortedLinks = currentLeaf.links.sorted()

            for childHash in sortedLinks {
                if visited.contains(childHash) { continue }
                guard let childLeaf = leafs[childHash] else { continue }

                let childClone = childLeaf.clone()
                let childSize = childClone.estimateSize()

                // Check if adding would exceed batch size
                if currentBatchSize + childSize > batchSize && !currentBatch.leaves.isEmpty {
                    // Finalize and start new batch
                    finalizeBatch(&currentBatch, parentsInBatch: parentsInBatch)
                    batches.append(currentBatch)

                    currentBatch = BatchedTransmissionPacket()
                    currentBatchSize = 0
                    parentsInBatch = Set<String>()
                }

                currentBatch.leaves.append(childClone)
                currentBatch.relationships[childClone.hash] = current
                currentBatchSize += childSize
                visited.insert(childHash)
                parentsInBatch.insert(childHash)
                queue.append(childHash)
            }
        }

        // Finalize last batch
        if !currentBatch.leaves.isEmpty {
            finalizeBatch(&currentBatch, parentsInBatch: parentsInBatch)
            batches.append(currentBatch)
        }

        // Set indices
        for i in 0..<batches.count {
            batches[i].packetIndex = i
            batches[i].totalPackets = batches.count
        }

        return batches
    }

    /// Generates Merkle proofs for parent leaves in a batch.
    private func finalizeBatch(_ batch: inout BatchedTransmissionPacket, parentsInBatch: Set<String>) {
        var parentChildrenInBatch: [String: [String]] = [:]
        for (childHash, parentHash) in batch.relationships where !parentHash.isEmpty {
            parentChildrenInBatch[parentHash, default: []].append(childHash)
        }

        let partial = isPartial()

        for parentHash in parentsInBatch {
            guard let parentLeaf = batch.leaves.first(where: { $0.hash == parentHash }) else { continue }
            guard let originalParent = leafs[parentHash] else { continue }

            let totalChildren = originalParent.currentLinkCount
            guard totalChildren > 1 else { continue }

            let childrenInThisBatch = parentChildrenInBatch[parentHash] ?? []
            if childrenInThisBatch.count == totalChildren {
                parentLeaf.proofs = [:]
                continue
            }

            if partial {
                guard !originalParent.proofs.isEmpty else { continue }
                parentLeaf.proofs = originalParent.proofs
                continue
            }

            // Full DAG: build the Merkle tree from the original parent's complete links.
            let builder = TreeContent()
            var sortedLinks = originalParent.links
            sortedLinks.sort()
            for link in sortedLinks {
                builder.addLeaf(key: link, data: link)
            }

            guard let (merkleTree, _) = try? builder.build() else { continue }

            if parentLeaf.proofs.isEmpty {
                parentLeaf.proofs = [:]
            }
            for linkHash in sortedLinks {
                let (index, exists) = merkleTree.getIndexForKey(linkHash)
                if exists && index < merkleTree.proofs.count {
                    parentLeaf.proofs[linkHash] = ClassicTreeBranch(
                        leaf: linkHash,
                        proof: merkleTree.proofs[index]
                    )
                }
            }
        }
    }

    /// Verifies a batched transmission packet.
    public func verifyBatchedTransmissionPacket(_ packet: BatchedTransmissionPacket) throws {
        var batchLeaves: [String: DagLeaf] = [:]
        for leaf in packet.leaves {
            batchLeaves[leaf.hash] = leaf
        }

        for childLeaf in packet.leaves {
            guard let parentHash = packet.relationships[childLeaf.hash] else {
                throw DagError.brokenDag("missing relationship for leaf \(childLeaf.hash)")
            }

            if parentHash.isEmpty {
                // Root leaf
                let tempDag = Dag(root: childLeaf.hash, leafs: [childLeaf.hash: childLeaf])
                try childLeaf.verifyRootLeaf(dag: tempDag)
            } else {
                try childLeaf.verifyLeaf()

                // Find parent (in batch or in existing DAG)
                let parentLeaf = batchLeaves[parentHash] ?? leafs[parentHash]
                if let parentLeaf = parentLeaf, parentLeaf.currentLinkCount > 1 {
                    if parentLeaf.proofs.isEmpty { continue }
                    guard let proof = parentLeaf.proofs[childLeaf.hash] else {
                        if batchLeaves[parentHash] != nil { continue }
                        throw DagError.brokenDag("missing proof for \(childLeaf.hash)")
                    }
                    try parentLeaf.verifyBranch(proof)
                }
            }
        }
    }

    /// Applies a batched transmission packet to this DAG.
    public func applyBatchedTransmissionPacket(_ packet: BatchedTransmissionPacket) {
        for leaf in packet.leaves {
            if let existing = leafs[leaf.hash] {
                // Merge proofs from incoming leaf
                for (k, v) in leaf.proofs {
                    existing.proofs[k] = v
                }
                // Merge links
                for link in leaf.links {
                    if !existing.hasLink(link) {
                        existing.addLink(link)
                    }
                }
            } else {
                leafs[leaf.hash] = leaf
            }

            guard let parentHash = packet.relationships[leaf.hash] else { continue }
            if parentHash.isEmpty {
                root = leaf.hash
            } else if let parent = leafs[parentHash] {
                if !parent.hasLink(leaf.hash) {
                    parent.addLink(leaf.hash)
                }
            }
        }
    }

    /// Verifies then applies a batched transmission packet.
    public func applyAndVerifyBatchedTransmissionPacket(_ packet: BatchedTransmissionPacket) throws {
        try verifyBatchedTransmissionPacket(packet)
        applyBatchedTransmissionPacket(packet)
    }
}

// MARK: - BatchedTransmissionPacket Helpers

extension BatchedTransmissionPacket {
    /// Returns the root leaf from this batch (the one with empty parent).
    public func getRootLeaf() -> DagLeaf? {
        for leaf in leaves {
            if let parentHash = relationships[leaf.hash], parentHash.isEmpty {
                return leaf
            }
        }
        return leaves.first
    }
}