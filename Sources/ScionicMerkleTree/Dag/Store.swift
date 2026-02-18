// Store.swift — Persistent storage interface for DAG leaves
//
// Ported from dag/store.go.
// Defines the LeafStore protocol and DagStore wrapper for persistent leaf storage.
// Consumers implement LeafStore to back with their own database/filesystem.

import Foundation

// MARK: - LeafStore Protocol

/// Protocol for persistent leaf storage backends.
///
/// Implement this protocol to store DAG leaves in a database, filesystem, etc.
/// The DagStore wrapper provides higher-level DAG operations on top.
public protocol LeafStore {
    /// Stores a leaf (without content).
    func storeLeaf(_ leaf: DagLeaf) throws
    /// Retrieves a leaf by hash (without content).
    func retrieveLeaf(_ hash: String) throws -> DagLeaf?
    /// Retrieves a leaf by hash (without content). Same as retrieveLeaf for basic stores.
    func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf?
    /// Checks if a leaf exists.
    func hasLeaf(_ hash: String) throws -> Bool
    /// Stores content separately (for streaming large files).
    func storeContent(_ hash: String, content: Data) throws
    /// Retrieves content separately.
    func retrieveContent(_ hash: String) throws -> Data?
}

// MARK: - DagStore

/// Wraps a LeafStore with DAG-level operations.
///
/// Provides convenience methods for storing/retrieving entire DAGs,
/// streaming content, batch operations, and relationship lookups.
public class DagStore {
    public let store: LeafStore
    public let rootHash: String

    public init(store: LeafStore, rootHash: String) {
        self.store = store
        self.rootHash = rootHash
    }

    /// Stores all leaves from a DAG.
    public func storeDag(_ dag: Dag) throws {
        for (_, leaf) in dag.leafs {
            try store.storeLeaf(leaf)
            if let content = leaf.content {
                try store.storeContent(leaf.hash, content: content)
            }
        }
    }

    /// Reconstructs a DAG from stored leaves.
    public func toDag() throws -> Dag {
        let dag = Dag(root: rootHash)

        // Start from root and traverse
        func loadLeaf(_ hash: String) throws {
            guard dag.leafs[hash] == nil else { return }
            guard let leaf = try store.retrieveLeaf(hash) else { return }

            // Load content if available
            if let content = try store.retrieveContent(hash) {
                leaf.content = content
            }

            dag.leafs[hash] = leaf

            // Recurse into children
            for childHash in leaf.links {
                try loadLeaf(childHash)
            }
        }

        try loadLeaf(rootHash)
        return dag
    }

    /// Stores multiple leaves in batch.
    public func storeLeavesInBatches(_ leaves: [DagLeaf]) throws {
        for leaf in leaves {
            try store.storeLeaf(leaf)
            if let content = leaf.content {
                try store.storeContent(leaf.hash, content: content)
            }
        }
    }
}

// MARK: - In-Memory Store (for testing)

/// Simple in-memory LeafStore implementation for testing.
public class InMemoryLeafStore: LeafStore {
    private var leaves: [String: DagLeaf] = [:]
    private var contents: [String: Data] = [:]

    public init() {}

    public func storeLeaf(_ leaf: DagLeaf) throws {
        leaves[leaf.hash] = leaf
    }

    public func retrieveLeaf(_ hash: String) throws -> DagLeaf? {
        return leaves[hash]?.clone()
    }

    public func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf? {
        guard let leaf = leaves[hash]?.clone() else { return nil }
        leaf.content = nil
        return leaf
    }

    public func hasLeaf(_ hash: String) throws -> Bool {
        return leaves[hash] != nil
    }

    public func storeContent(_ hash: String, content: Data) throws {
        contents[hash] = content
    }

    public func retrieveContent(_ hash: String) throws -> Data? {
        return contents[hash]
    }
}
