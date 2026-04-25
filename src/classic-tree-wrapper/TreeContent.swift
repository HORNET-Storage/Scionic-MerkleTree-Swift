// TreeContent.swift — Key/value wrapper around Classic Merkle Trees
//
// Ported from Go's tree/tree.go. Wraps MerkleTree for convenient key->value usage.
// Used by the DAG package to build Classic Merkle Trees from link lists.

import Foundation

// MARK: - TreeLeaf (DataBlock for string data)

/// A simple DataBlock that wraps a string.
/// Mirrors Go's `tree.Leaf` where `Serialize()` returns `[]byte(b.data)`.
public struct TreeLeaf: DataBlock {
    public let data: String

    public init(_ data: String) {
        self.data = data
    }

    public func serialize() throws -> Data {
        return Data(data.utf8)
    }
}

// MARK: - TreeContent

/// A builder for Classic Merkle Trees from string key-value pairs.
///
/// Used by the DAG package to build the Classic Merkle Tree inside parent leaves:
/// ```swift
/// let tree = TreeContent()
/// for link in links {
///     tree.addLeaf(key: link, data: link)
/// }
/// let (merkleTree, leafMap) = try tree.build()
/// ```
public class TreeContent {
    private var leafs: [String: DataBlock] = [:]

    public init() {}

    /// Adds a named leaf with string data.
    public func addLeaf(key: String, data: String) {
        leafs[key] = TreeLeaf(data)
    }

    /// Builds the Merkle Tree from all added leaves.
    ///
    /// Keys are sorted alphabetically to ensure deterministic tree construction.
    /// Returns the built tree and the leaf map (key -> DataBlock).
    public func build() throws -> (MerkleTree, [String: DataBlock]) {
        let tree = try MerkleTree.build(config: nil, blocks: leafs)
        return (tree, leafs)
    }
}

// MARK: - Verification Helpers

/// Verifies all proofs in a Merkle Tree against their leaves.
public func verifyTree(_ tree: MerkleTree, leaves: [DataBlock]) -> Bool {
    guard tree.proofs.count == leaves.count else { return false }

    for i in 0..<leaves.count {
        do {
            try tree.verify(dataBlock: leaves[i], proof: tree.proofs[i])
        } catch {
            return false
        }
    }
    return true
}

/// Verifies proofs against a root hash (without needing the full tree).
public func verifyRoot(_ root: Data, proofs: [Proof], leaves: [DataBlock]) -> Bool {
    guard proofs.count == leaves.count else { return false }

    for i in 0..<leaves.count {
        do {
            try MerkleTree.verify(dataBlock: leaves[i], proof: proofs[i], root: root, config: nil)
        } catch {
            return false
        }
    }
    return true
}
