// Store.swift — Persistent storage interface for DAG leaves
//
// Ported from dag/store.go.
//
// Key types:
//   - LeafStore protocol — interface for persistent leaf storage
//   - DagStore — wraps LeafStore with DAG-level operations
//   - RelationshipCache — parent-child lookup cache
//
// Key functions:
//   - DagStore.createDirectoryStreaming(path) throws
//   - DagStore.getContentFromLeafStreaming(leaf) -> Data
//   - DagStore.storeLeavesInBatches(leaves) throws
//   - DagStore.verifyPartialDag() throws
//   - DagStore.isPartial() -> Bool
//
// TODO: Implement in Task #12

import Foundation