// DagVerification.swift — DAG verification, iteration, directory recreation, labels
//
// Ported from dag/dag.go (verification and utility portion).

import Foundation

// MARK: - Verification

extension Dag {

    /// Verifies the DAG integrity, auto-detecting full vs partial.
    ///
    /// Mirrors Go's `Verify()`. Full DAGs use parent-child traversal,
    /// partial DAGs use stored Merkle proofs for path-to-root verification.
    public func verify() throws {
        if isPartial() {
            try verifyWithProofs()
        } else {
            try verifyFullDag()
        }
    }

    /// Verifies a full DAG by iterating all leaves and checking parent-child relationships.
    private func verifyFullDag() throws {
        var visited = Set<String>()

        try iterateDag { leaf, parent in
            visited.insert(leaf.hash)

            if leaf.hash == self.root {
                try leaf.verifyRootLeaf(dag: self)
                // Verify root's children against merkle root if we have all children
                if leaf.links.count == leaf.currentLinkCount && leaf.currentLinkCount > 0 {
                    try leaf.verifyChildrenAgainstMerkleRoot(dag: self)
                }
            } else {
                try leaf.verifyLeaf()

                guard let parent = parent else {
                    throw DagError.brokenPathToRoot(leaf.hash)
                }
                guard parent.hasLink(leaf.hash) else {
                    throw DagError.brokenDag("parent \(parent.hash) does not contain link to child \(leaf.hash)")
                }

                // Verify parent's merkle root if we have all children
                if parent.links.count == parent.currentLinkCount && parent.currentLinkCount > 0 {
                    try parent.verifyChildrenAgainstMerkleRoot(dag: self)
                }
            }
        }

        if visited.count != leafs.count {
            throw DagError.brokenDag("dag contains \(leafs.count - visited.count) unreachable leaves")
        }
    }

    /// Verifies a partial DAG using stored Merkle proofs.
    private func verifyWithProofs() throws {
        guard let rootLeaf = leafs[root] else {
            throw DagError.brokenDag("root leaf not found")
        }

        // Verify root leaf
        try rootLeaf.verifyRootLeaf(dag: self)

        // Check root's children
        if rootLeaf.links.count == rootLeaf.currentLinkCount && rootLeaf.currentLinkCount > 0 {
            let childrenInDag = rootLeaf.links.filter { leafs[$0] != nil }.count
            if childrenInDag == rootLeaf.currentLinkCount {
                try rootLeaf.verifyChildrenAgainstMerkleRoot(dag: self)
            } else if rootLeaf.currentLinkCount == 1 {
                // Single child case
                if childrenInDag > 0 {
                    let childHash = rootLeaf.links[0]
                    if leafs[childHash] != nil {
                        guard String(data: rootLeaf.classicMerkleRoot, encoding: .utf8) == childHash ||
                              rootLeaf.classicMerkleRoot == Data(childHash.utf8) else {
                            throw DagError.brokenDag("single child verification failed")
                        }
                    }
                }
            } else if rootLeaf.proofs.isEmpty {
                throw DagError.brokenDag("root has \(rootLeaf.currentLinkCount) links but only \(childrenInDag) children exist (no proofs)")
            }
        }

        // Verify each non-root leaf
        for (_, leaf) in leafs {
            if leaf.hash == root { continue }

            try leaf.verifyLeaf()

            // Verify path to root
            var current = leaf
            while current.hash != root {
                // Find parent
                var parent: DagLeaf? = nil
                for (_, potential) in leafs {
                    if potential.hasLink(current.hash) {
                        parent = potential
                        break
                    }
                }
                guard let parent = parent else {
                    throw DagError.brokenPathToRoot(leaf.hash)
                }

                if parent.hash != root {
                    try parent.verifyLeaf()
                }

                // Check merkle proof if needed
                let hasAllChildren = parent.links.count == parent.currentLinkCount
                if hasAllChildren && parent.currentLinkCount > 0 {
                    let childrenInDag = parent.links.filter { leafs[$0] != nil }.count
                    if childrenInDag == parent.currentLinkCount {
                        try parent.verifyChildrenAgainstMerkleRoot(dag: self)
                    } else if let proof = parent.proofs[current.hash] {
                        do {
                            try parent.verifyBranch(proof)
                        } catch {
                            throw DagError.brokenDag("invalid merkle proof for node \(current.hash): \(error)")
                        }
                    } else if parent.currentLinkCount > 1 {
                        throw DagError.brokenDag("missing merkle proof for \(current.hash) in partial DAG")
                    }
                } else if parent.currentLinkCount > 1 {
                    guard let proof = parent.proofs[current.hash] else {
                        throw DagError.brokenDag("missing merkle proof for \(current.hash)")
                    }
                    do {
                        try parent.verifyBranch(proof)
                    } catch {
                        throw DagError.brokenDag("invalid merkle proof for node \(current.hash): \(error)")
                    }
                }

                current = parent
            }
        }
    }
}

// MARK: - Iteration

extension Dag {

    /// Iterates the DAG depth-first from root, calling the callback for each leaf.
    ///
    /// Mirrors Go's `IterateDag`. The callback receives (leaf, parent) where parent is nil for root.
    public func iterateDag(_ processLeaf: (DagLeaf, DagLeaf?) throws -> Void) throws {
        func iterate(leafHash: String, parentHash: String?) throws {
            guard let leaf = leafs[leafHash] else {
                throw DagError.childMissing(leafHash)
            }

            var parent: DagLeaf? = nil
            if let ph = parentHash {
                parent = leafs[ph]
            }

            try processLeaf(leaf, parent)

            // Recurse into children (sorted by hash for determinism)
            let childHashes = leaf.links
            for childHash in childHashes {
                try iterate(leafHash: childHash, parentHash: leaf.hash)
            }
        }

        try iterate(leafHash: root, parentHash: nil)
    }
}

// MARK: - Directory Recreation

extension Dag {

    /// Recreates the filesystem directory structure from the DAG.
    ///
    /// Mirrors Go's `CreateDirectory`.
    public func createDirectory(path: String) throws {
        guard let rootLeaf = leafs[root] else {
            throw DagError.brokenDag("root leaf not found")
        }
        try createDirectoryLeaf(leaf: rootLeaf, path: path)
    }

    private func createDirectoryLeaf(leaf: DagLeaf, path: String) throws {
        let fm = FileManager.default

        switch leaf.type {
        case .directory:
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)

            for link in leaf.links {
                guard let childLeaf = leafs[link] else {
                    throw DagError.invalidLink(link)
                }
                let childPath = (path as NSString).appendingPathComponent(childLeaf.itemName)
                try createDirectoryLeaf(leaf: childLeaf, path: childPath)
            }

        case .file:
            let content = try getContentFromLeaf(leaf)
            try content.write(to: URL(fileURLWithPath: path))

        case .chunk:
            // Chunks are handled by their parent file leaf
            break
        }
    }
}

// MARK: - Content Assembly

extension Dag {

    /// Assembles file content from a leaf's chunks.
    ///
    /// Mirrors Go's `GetContentFromLeaf`. For chunked files, sorts chunks by
    /// ItemName (numeric basename) and concatenates their content.
    public func getContentFromLeaf(_ leaf: DagLeaf) throws -> Data {
        if !leaf.links.isEmpty {
            // Chunked file: collect and sort chunks by numeric ItemName
            struct LinkInfo {
                let hash: String
                let leaf: DagLeaf
                let itemName: String
            }

            var links: [LinkInfo] = []
            for link in leaf.links {
                guard let childLeaf = leafs[link] else {
                    throw DagError.invalidLink(link)
                }
                links.append(LinkInfo(hash: link, leaf: childLeaf, itemName: childLeaf.itemName))
            }

            // Sort by numeric basename (extract last path component)
            links.sort { a, b in
                let baseA = (a.itemName as NSString).lastPathComponent
                let baseB = (b.itemName as NSString).lastPathComponent
                if let numA = Int(baseA), let numB = Int(baseB) {
                    return numA < numB
                }
                return a.itemName < b.itemName
            }

            var content = Data()
            for linkInfo in links {
                if let c = linkInfo.leaf.content {
                    content.append(c)
                }
            }
            return content

        } else if let content = leaf.content, !content.isEmpty {
            return content
        }

        return Data()
    }
}

// MARK: - Partial DAG

extension Dag {

    /// Creates a partial DAG with specified leaves and their verification paths.
    ///
    /// Mirrors Go's `GetPartial`. Each requested leaf gets a path to root with Merkle proofs.
    /// - Parameters:
    ///   - leafHashes: CID hashes of the leaves to include
    ///   - pruneLinks: if true, remove links not needed for verification
    public func getPartial(leafHashes: [String], pruneLinks: Bool) throws -> Dag {
        guard !leafHashes.isEmpty else {
            throw DagError.brokenDag("no leaf hashes provided")
        }

        let partial = Dag(root: root)
        var relevantHashes: Set<String> = [root]

        for requestedHash in leafHashes {
            guard let targetLeaf = leafs[requestedHash] else {
                throw DagError.childMissing(requestedHash)
            }

            relevantHashes.insert(requestedHash)

            // Build verification path from leaf to root
            let branch = try buildVerificationBranch(targetLeaf)

            for pathNode in branch.path {
                relevantHashes.insert(pathNode.hash)
            }

            // Add branch to partial
            addBranchToPartial(branch, partial: partial)
        }

        if pruneLinks {
            pruneIrrelevantLinks(partial: partial, relevantHashes: relevantHashes)
        }

        return partial
    }

    func buildVerificationBranch(_ leaf: DagLeaf) throws -> DagBranch {
        let rootLeaf = leafs[root]!.clone()

        var branch = DagBranch(leaf: leaf.clone(), path: [rootLeaf])

        var current = leaf
        while current.hash != root {
            // Find parent
            var parent: DagLeaf? = nil
            for (_, potential) in leafs {
                if potential.hasLink(current.hash) {
                    parent = potential
                    break
                }
            }
            guard let parent = parent else {
                throw DagError.brokenPathToRoot(current.hash)
            }

            let parentClone = parent.clone()

            // Generate merkle proof if parent has multiple children
            if parent.currentLinkCount > 1 {
                let builder = TreeContent()
                for h in parent.links {
                    builder.addLeaf(key: h, data: h)
                }
                let (merkleTree, _) = try builder.build()

                let (index, exists) = merkleTree.getIndexForKey(current.hash)
                guard exists else {
                    throw DagError.brokenDag("unable to find index for key \(current.hash)")
                }

                let proof = ClassicTreeBranch(
                    leaf: current.hash,
                    proof: merkleTree.proofs[index]
                )
                parentClone.proofs[current.hash] = proof
            }

            branch.path.append(parentClone)
            current = parent
        }

        return branch
    }

    private func addBranchToPartial(_ branch: DagBranch, partial: Dag) {
        // Add leaf
        if partial.leafs[branch.leaf.hash] == nil {
            partial.leafs[branch.leaf.hash] = branch.leaf
        }

        // Add path nodes and merge proofs
        for pathNode in branch.path {
            if let existing = partial.leafs[pathNode.hash] {
                let merged = existing.clone()
                for (k, v) in pathNode.proofs {
                    merged.proofs[k] = v
                }
                partial.leafs[pathNode.hash] = merged
            } else {
                partial.leafs[pathNode.hash] = pathNode
            }
        }

        // Establish parent-child links
        if !branch.path.isEmpty {
            let directParent = branch.path[branch.path.count - 1]
            if directParent.hasLink(branch.leaf.hash) {
                if let partialNode = partial.leafs[directParent.hash] {
                    if !partialNode.hasLink(branch.leaf.hash) {
                        partialNode.addLink(branch.leaf.hash)
                    }
                }
            }
        }

        for i in 0..<(branch.path.count - 1) {
            let current = branch.path[i]
            let next = branch.path[i + 1]
            if current.hasLink(next.hash) {
                if let partialNode = partial.leafs[current.hash] {
                    if !partialNode.hasLink(next.hash) {
                        partialNode.addLink(next.hash)
                    }
                }
            }
        }
    }

    private func pruneIrrelevantLinks(partial: Dag, relevantHashes: Set<String>) {
        for (_, leaf) in partial.leafs {
            leaf.links = leaf.links.filter { relevantHashes.contains($0) }
        }
    }
}

// MARK: - Labels

extension Dag {

    /// Assigns deterministic numeric labels to all leaves via DAG traversal order.
    ///
    /// Root is always label "0" (implicit, not stored). Other leaves get "1", "2", etc.
    public func calculateLabels() throws {
        labels = [:]
        var labelCounter = 1

        try iterateDag { leaf, _ in
            if leaf.hash == self.root { return }
            let label = "\(labelCounter)"
            self.labels[label] = leaf.hash
            labelCounter += 1
        }
    }

    /// Removes all label assignments.
    public func clearLabels() {
        labels = [:]
    }

    /// Returns leaf hashes for a range of labels (inclusive).
    public func getHashesByLabelRange(start: Int, end: Int) throws -> [String] {
        guard !labels.isEmpty else {
            throw DagError.brokenDag("labels not calculated")
        }
        guard start >= 1 else {
            throw DagError.brokenDag("start label must be >= 1")
        }
        guard end >= start else {
            throw DagError.brokenDag("end label must be >= start label")
        }

        var hashes: [String] = []
        for i in start...end {
            guard let hash = labels["\(i)"] else {
                throw DagError.brokenDag("label \(i) not found")
            }
            hashes.append(hash)
        }
        return hashes
    }

    /// Returns the label for a given leaf hash.
    public func getLabel(hash: String) throws -> String {
        if hash == root { return "0" }
        guard !labels.isEmpty else {
            throw DagError.brokenDag("labels not calculated")
        }
        for (label, labelHash) in labels {
            if labelHash == hash {
                return label
            }
        }
        throw DagError.childMissing(hash)
    }
}
