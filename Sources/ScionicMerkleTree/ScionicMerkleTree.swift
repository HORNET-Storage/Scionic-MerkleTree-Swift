// ScionicMerkleTree — Swift port of github.com/HORNET-Storage/Scionic-Merkle-Tree
//
// A hybrid Merkle DAG / Merkle Tree data structure that combines:
// - The folder storage support of Merkle DAGs
// - The small branches (logarithmic proofs) of Classic Merkle Trees
// - Numbered leaves for LeafSync range-based synchronization
//
// Architecture:
//   Internal/       — CBOR encoding, CID generation, base encodings (no external deps except swift-crypto)
//   MerkleTree/     — Classic Merkle Tree with proof generation/verification (ported from go-merkletree)
//   Tree/           — High-level key-value Merkle Tree wrapper
//   Dag/            — Core DAG types, leaf building, creation, verification, serialization, transmission
//   Diff/           — DAG diffing and patching
//   Store/          — Persistent storage interface

/// Library version matching the Go v2 module
public let version = "2.0.0"