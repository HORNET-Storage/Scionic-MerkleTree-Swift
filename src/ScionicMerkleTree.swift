// ScionicMerkleTree — Swift port of github.com/HORNET-Storage/Scionic-Merkle-Tree
//
// A hybrid Merkle DAG / Merkle Tree data structure that combines:
// - The folder storage support of Merkle DAGs
// - The small branches (logarithmic proofs) of Classic Merkle Trees
// - Numbered leaves for LeafSync range-based synchronization
//
// Architecture mirrors the Go repository inside SwiftPM's configured source path:
//   dag/         — Scionic DAG types, leaves, creation, verification, serialization, transmission, store
//   diff/        — DAG diffing and patching
//   classic-merkle-tree/ — Classic Merkle Tree proof generation and verification
//   classic-tree-wrapper/ — Key/value wrapper around Classic Merkle Trees
//   testutil/    — Fixture builders used by parity tests
//   internal/    — CBOR encoding, CID generation, base encodings

/// Library version matching the Go v2 module
public let version = "2.0.0"