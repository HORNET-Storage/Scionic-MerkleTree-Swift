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
    /// Adds the leaf, establishes parent link, and stores proofs.
    public func applyTransmissionPacket(_ packet: TransmissionPacket) {
        leafs[packet.leaf.hash] = packet.leaf

        // Establish parent-child link
        if !packet.parentHash.isEmpty {
            if let parent = leafs[packet.parentHash] {
                if !parent.hasLink(packet.leaf.hash) {
                    parent.addLink(packet.leaf.hash)
                }
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
