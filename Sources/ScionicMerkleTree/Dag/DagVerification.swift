// DagVerification.swift — DAG verification, iteration, and directory recreation
//
// Ported from dag/dag.go (verification and utility portion).
//
// Key functions:
//   - Dag.verify() throws — auto-detects full vs partial, dispatches
//   - Dag.verifyFullDag() throws — checks all parent-child relationships
//   - Dag.verifyWithProofs() throws — verifies partial DAGs via stored Merkle proofs
//   - Dag.isPartial() -> Bool
//   - Dag.iterateDag(callback) throws — breadth-first traversal
//   - Dag.createDirectory(path) throws — recreates filesystem from DAG
//   - Dag.getContentFromLeaf(leaf) -> Data — assembles content from chunks
//   - Dag.getPartial(leafHashes, pruneLinks) -> Dag
//   - ReadDag(path) -> Dag — reads CBOR file
//
// TODO: Implement in Task #8

import Foundation