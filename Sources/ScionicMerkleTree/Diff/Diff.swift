// Diff.swift — DAG diffing and patching
//
// Ported from diff/diff.go.

import Foundation

// MARK: - Types

public enum DiffType: String {
    case added = "added"
    case removed = "removed"
}

public struct LeafDiff {
    public var type: DiffType
    public var hash: String
    public var leaf: DagLeaf
}

public struct DiffSummary {
    public var added: Int = 0
    public var removed: Int = 0
    public var total: Int = 0
}

public class DagDiff {
    public var diffs: [String: LeafDiff] = [:]
    public var summary: DiffSummary = DiffSummary()

    public init() {}

    /// Returns all added leaves.
    public func getAddedLeaves() -> [String: DagLeaf] {
        var result: [String: DagLeaf] = [:]
        for (hash, d) in diffs where d.type == .added {
            result[hash] = d.leaf
        }
        return result
    }

    /// Returns all removed leaves.
    public func getRemovedLeaves() -> [String: DagLeaf] {
        var result: [String: DagLeaf] = [:]
        for (hash, d) in diffs where d.type == .removed {
            result[hash] = d.leaf
        }
        return result
    }

    /// Applies the diff to an old DAG, creating a new DAG.
    ///
    /// Pools all leaves (old + added), finds the new root among added leaves,
    /// then traverses from root to collect only referenced leaves.
    public func applyToDAG(_ oldDag: Dag) throws -> Dag {
        if summary.added == 0 {
            let newDag = Dag(root: oldDag.root)
            for (hash, leaf) in oldDag.leafs {
                newDag.leafs[hash] = leaf
            }
            return newDag
        }

        // Build leaf pool
        var leafPool: [String: DagLeaf] = [:]
        for (hash, leaf) in oldDag.leafs {
            leafPool[hash] = leaf
        }
        for (hash, d) in diffs where d.type == .added {
            leafPool[hash] = d.leaf
        }

        // Find new root among added leaves (not referenced by any other, has LeafCount > 0)
        let addedLeaves = getAddedLeaves()
        var childHashes = Set<String>()
        for (_, leaf) in leafPool {
            for childHash in leaf.links {
                childHashes.insert(childHash)
            }
        }

        var newRootHash = ""
        for (hash, leaf) in addedLeaves {
            if !childHashes.contains(hash) && leaf.leafCount > 0 {
                newRootHash = hash
                break
            }
        }

        guard !newRootHash.isEmpty else {
            throw DagError.brokenDag("cannot find new root among added leaves")
        }

        // Traverse from new root to collect referenced leaves
        var newDagLeaves: [String: DagLeaf] = [:]
        var visited = Set<String>()

        func traverse(_ hash: String) throws {
            if visited.contains(hash) { return }
            visited.insert(hash)

            guard let leaf = leafPool[hash] else {
                throw DagError.childMissing(hash)
            }
            newDagLeaves[hash] = leaf

            for childHash in leaf.links {
                try traverse(childHash)
            }
        }

        try traverse(newRootHash)

        return Dag(root: newRootHash, leafs: newDagLeaves)
    }

    /// Creates a partial DAG containing only the added leaves with paths to root.
    public func createPartialDag(fullNewDag: Dag) throws -> Dag {
        let addedLeaves = getAddedLeaves()
        guard !addedLeaves.isEmpty else {
            throw DagError.brokenDag("no added leaves to create partial DAG")
        }

        let addedHashes = Array(addedLeaves.keys)
        return try fullNewDag.getPartial(leafHashes: addedHashes, pruneLinks: false)
    }
}

// MARK: - Diff Functions

/// Computes the diff between two full DAGs.
///
/// Mirrors Go's `Diff(firstDag, secondDag)`. Compares by hash —
/// leaves present in second but not first are "added",
/// leaves present in first but not second are "removed".
public func dagDiff(first: Dag, second: Dag) -> DagDiff {
    let result = DagDiff()

    // Find added leaves (in second but not in first)
    for (hash, newLeaf) in second.leafs {
        if first.leafs[hash] == nil {
            result.diffs[hash] = LeafDiff(type: .added, hash: hash, leaf: newLeaf)
            result.summary.added += 1
            result.summary.total += 1
        }
    }

    // Find removed leaves (in first but not in second)
    for (hash, oldLeaf) in first.leafs {
        if second.leafs[hash] == nil {
            result.diffs[hash] = LeafDiff(type: .removed, hash: hash, leaf: oldLeaf)
            result.summary.removed += 1
            result.summary.total += 1
        }
    }

    return result
}

/// Computes diff from new leaves (e.g., from a partial DAG).
///
/// Mirrors Go's `DiffFromNewLeaves`. Identifies added leaves and
/// removed leaves no longer reachable from the new root.
public func diffFromNewLeaves(originalDag: Dag, newLeaves: [String: DagLeaf]) -> DagDiff {
    let result = DagDiff()

    let oldLeafs = originalDag.leafs

    // Find new root (leaf with LeafCount > 0)
    var newRoot: DagLeaf? = nil
    var newRootHash = ""
    var newLeafsMap: [String: DagLeaf] = [:]
    for (hash, leaf) in newLeaves {
        newLeafsMap[hash] = leaf
        if leaf.leafCount > 0 {
            newRoot = leaf
            newRootHash = hash
        }
    }

    // Find added leaves
    for (hash, newLeaf) in newLeafsMap {
        if oldLeafs[hash] == nil {
            result.diffs[hash] = LeafDiff(type: .added, hash: hash, leaf: newLeaf)
            result.summary.added += 1
            result.summary.total += 1
        }
    }

    // Find removed leaves — old leaves not reachable from new root
    var reachable = Set<String>()
    if newRoot != nil {
        func traverse(_ hash: String) {
            if reachable.contains(hash) { return }
            reachable.insert(hash)

            var leaf: DagLeaf? = newLeafsMap[hash]
            if leaf == nil { leaf = oldLeafs[hash] }

            if let leaf = leaf {
                for childHash in leaf.links {
                    traverse(childHash)
                }
            }
        }
        traverse(newRootHash)
    }

    for (hash, oldLeaf) in oldLeafs {
        if !reachable.contains(hash) {
            result.diffs[hash] = LeafDiff(type: .removed, hash: hash, leaf: oldLeaf)
            result.summary.removed += 1
            result.summary.total += 1
        }
    }

    return result
}
