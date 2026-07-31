// ParentIndex.swift — the single child -> parent rule

import Foundation

/// Resolves each child to its **lowest** parent hash.
///
/// A content-identical chunk leaf can be linked by several parents, so "the"
/// parent of a shared leaf is only well defined if every code path picks the
/// same one. This is that rule, and every path that derives a child -> parent
/// mapping routes through it.
///
/// Keeping whichever parent was seen first made the answer depend on dictionary
/// order in one path and on BFS traversal order in another, so the same DAG
/// reported a different `parentHash` for a shared chunk depending on whether it
/// had been deserialized or loaded from a store. `parentHash` is never
/// transmitted — it is absent from the serializable leaf — which is exactly why
/// the disagreement went unnoticed: nothing on the wire contradicted it.
///
/// Taking the minimum is independent of iteration order, so this is
/// deterministic even though it ranges over a dictionary.
///
/// Mirrors Go's `minimumParentIndex` and Rust's `minimum_parent_index`.
func minimumParentIndex(_ children: [String: [String]]) -> [String: String] {
    var parentOf: [String: String] = [:]
    parentOf.reserveCapacity(children.count)
    for (parentHash, childHashes) in children {
        for childHash in childHashes {
            if let existing = parentOf[childHash] {
                if parentHash < existing {
                    parentOf[childHash] = parentHash
                }
            } else {
                parentOf[childHash] = parentHash
            }
        }
    }
    return parentOf
}
