# ScionicMerkleTree (Swift)

Swift port of [Scionic-Merkle-Tree](https://github.com/HORNET-Storage/Scionic-Merkle-Tree) — a hybrid Merkle DAG / Merkle Tree data structure.

## Features

- **Folder support** — directories and subdirectories of files, like Merkle DAGs
- **Small branches** — logarithmic proof sizes via Classic Merkle Trees inside parent leaves
- **LeafSync** — numbered leaves for range-based synchronization
- **Streaming I/O** — memory-efficient file chunking (one chunk in memory at a time)
- **Parallel creation** — optional parallel DAG building via Swift concurrency
- **Diffing** — compute and apply diffs between DAG versions
- **Cross-platform** — builds on macOS, iOS, Linux, and Windows

## Requirements

- Swift 5.9+
- Platforms: macOS 12+, iOS 15+, Linux, Windows (ARM64)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/YOUR-ORG/ScionicMerkleTreeSwift.git", from: "1.0.0"),
]
```

Then add `"ScionicMerkleTree"` as a dependency of your target.

## Usage

```swift
import ScionicMerkleTree

// Create a DAG from a directory
let dag = try CreateDag(path: "/path/to/directory", timestampRoot: true)

// Verify the DAG
try dag.verify()

// Recreate the directory from the DAG
try dag.createDirectory(path: "/path/to/output")

// Serialize to CBOR or JSON
let cborData = try dag.toCBOR()
let jsonData = try dag.toJSON()

// Deserialize
let restored = try Dag.fromCBOR(cborData)
```

## Architecture

```
Sources/ScionicMerkleTree/
├── Internal/           — CBOR, CID, Base encodings (zero deps except swift-crypto)
├── MerkleTree/         — Classic Merkle Tree (ported from go-merkletree)
├── Tree/               — Key-value Merkle Tree wrapper
├── Dag/                — Core: types, leaves, creation, verification, serialization, transmission, store
└── Diff/               — DAG diffing and patching
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 hashing (cross-platform) |

Everything else (CBOR, CID, base encodings, Merkle tree) is implemented directly — zero additional external dependencies.

## Compatibility

This library produces **hash-compatible** CIDs with the Go implementation:
- CID v1 with CBOR codec (`0x51`) and SHA2-256 multihash (`0x12`)
- Deterministic CBOR encoding matching `fxamacker/cbor/v2`
- Identical Merkle tree construction matching the modified `go-merkletree`

## License

MIT