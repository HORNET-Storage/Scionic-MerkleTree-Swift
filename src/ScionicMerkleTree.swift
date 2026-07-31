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

/// Library version, mirroring the Go release this port reproduces byte for byte.
///
/// This is a parity claim rather than an independent release history — see
/// `PARITY_SPEC.md`. It had silently drifted to `2.0.0` while the package was
/// tagged `v2.4.0`; keep it in step with the tag.
public let version = "2.4.1"