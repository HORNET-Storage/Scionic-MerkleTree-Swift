# ScionicMerkleTree (Swift)

A comprehensive Swift port of [Scionic-Merkle-Tree](https://github.com/HORNET-Storage/Scionic-Merkle-Tree) — a hybrid Merkle DAG / Merkle Tree data structure that combines the folder support of IPFS Merkle DAGs with the small branches of Classic Merkle Trees.

**Proven byte-identical with the Go implementation** — 12 cross-compatibility tests verify that Swift produces the exact same CID hashes as Go for the same input, from individual leaves to full multi-level directory DAGs.

## What’s Ported

This is a near-complete port of the Go library. **17 source files, ~6,300 lines of Swift, 93 tests.**

### Core (fully ported)

| Go File | Swift File | Status | Description |
|---------|-----------|--------|-------------|
| `dag/types.go` | `Dag/Types.swift` | ✅ Complete | All types: Dag, DagLeaf, DagBuilder, DagLeafBuilder, ClassicTreeBranch, DagBranch, TransmissionPacket, BatchedTransmissionPacket, DagBuilderConfig, LeafType, LeafProcessor |
| `dag/leaves.go` | `Dag/Leaves.swift` | ✅ Complete | BuildLeaf, BuildRootLeaf, VerifyLeaf, VerifyRootLeaf (with ContentSize/DagSize validation), VerifyChildrenAgainstMerkleRoot, GetBranch, VerifyBranch, HasLink, AddLink, Clone, EstimateSize |
| `dag/dag.go` | `Dag/DagCreation.swift` + `DagVerification.swift` | ✅ Complete | CreateDag, CreateDagAdvanced, CreateDagCustom, CreateDagWithConfig, parallel creation (DispatchQueue worker pool), Verify (full + partial with Merkle proofs), IterateDag, CreateDirectory, GetContentFromLeaf, GetPartial, CalculateLabels, GetHashesByLabelRange, GetLabel, IsPartial |
| `dag/serialize.go` | `Dag/Serialization.swift` | ✅ Complete | ToJSON, FromJSON, ToCBOR, FromCBOR, ReadDag, ToSerializable, FromSerializable (rebuilds Merkle trees + parent hashes) |
| `dag/transmission.go` | `Dag/Transmission.swift` | ✅ Complete | GetLeafSequence (BFS with proofs), VerifyTransmissionPacket, ApplyTransmissionPacket, ApplyAndVerifyTransmissionPacket, RemoveAllContent, GetBatchedLeafSequence (size-limited batches), VerifyBatchedTransmissionPacket, ApplyBatchedTransmissionPacket, BatchedTransmissionPacket.GetRootLeaf |
| `dag/store.go` | `Dag/Store.swift` | ✅ Complete | LeafStore, ContentStore, BatchLeafStore, BatchContentStore, LeafCounter, LeafEnumerator protocols. DagStore class with all operations. MemoryLeafStore + MemoryContentStore implementations |
| `dag/utils.go` | `Dag/Utils.swift` | ✅ Complete | SortMapByKeys, SortMapForVerification, KeyValue, CalculateTotalContentSize, CalculateTotalDagSize |
| `diff/diff.go` | `Diff/Diff.swift` | ✅ Complete | Diff, DiffFromNewLeaves, GetAddedLeaves, GetRemovedLeaves, ApplyToDAG, CreatePartialDag |
| `merkletree/merkletree.go` | `MerkleTree/*.swift` | ✅ Complete | Full Classic Merkle Tree: build from map, proof generation, proof verification, configurable hash function, OpenZeppelin-compatible sorting, GetIndexForKey |
| `tree/tree.go` | `Tree/TreeContent.swift` | ✅ Complete | TreeContent, TreeLeaf, Build, VerifyTree, VerifyRoot |

### Internal (implemented from scratch, no external deps)

| Component | Swift File | What it replaces |
|-----------|-----------|------------------|
| CBOR Encoder/Decoder | `Internal/CBOR.swift` | `fxamacker/cbor/v2` — deterministic encoding matching Go’s defaults |
| CID Generation | `Internal/CID.swift` | `go-cid` + `go-multihash` + `go-multicodec` — CIDv1 with CBOR codec (0x51) + SHA2-256 |
| Base32lower | `Internal/BaseEncoding.swift` | `go-multibase` — RFC 4648 lowercase, no padding |
| Base58btc | `Internal/BaseEncoding.swift` | `mr-tron/base58` — Bitcoin-style encoding |
| Varint | `Internal/Varint.swift` | `go-varint` — unsigned LEB128 |

## Cross-Compatibility Proof

**12 cross-compatibility tests** verify byte-identical output between Go and Swift at every level of the stack:

| Layer | Test | Verified |
|-------|------|----------|
| Classic Merkle Tree | 2, 3, 5, 100-leaf trees | Root hashes + proof paths + siblings match |
| Individual leaf hashing | file, chunk, directory leaves | CID strings match |
| Leaf with content | SHA-256 content hash | CID matches |
| Leaf with metadata | AdditionalData map | CID matches |
| Full DAG (manual) | 2 files + root directory | Root hash + child hashes + LeafCount + ContentSize + DagSize match |
| Full DAG (filesystem) | 3 files + 1 subdir | Root hash matches, verify passes, directory recreation matches |
| **Deep directory** | **7 files, 4 subdirs, 3 levels deep** | **All 12 leaf hashes match, verify passes, all file contents recreated correctly** |

The deep directory test creates this structure in both Go and Swift:
```
testdir/
├── readme.txt
├── docs/
│   ├── guide.txt
│   └── api.txt
├── src/
│   ├── main.txt
│   └── lib/
│       ├── utils.txt
│       └── helpers.txt
└── data/
    └── config.txt
```

Both produce root hash `bafireidb74bnd3jalcdjrog3sgnfdkxblqlphtkvbycksk3qpvrzbwzntu` — every leaf, every directory, every byte.

## Features

- **Directory support** — entire directory trees become Scionic Merkle DAGs, like IPFS
- **Small Merkle branches** — logarithmic proof sizes via Classic Merkle Trees inside parent leaves
- **LeafSync** — numbered leaves with label-based range queries for synchronization
- **Streaming I/O** — files read in chunks, one chunk in memory at a time
- **Parallel creation** — `createDagWithConfig` with `enableParallel: true` uses DispatchQueue worker pools
- **Verification** — full DAG verification + partial DAG verification with stored Merkle proofs
- **ContentSize/DagSize validation** — root leaf recalculates and verifies sizes from children
- **Serialization** — JSON and CBOR round-trip through SerializableDag intermediate
- **Transmission** — individual packets (GetLeafSequence) and batched packets (GetBatchedLeafSequence)
- **Diffing** — compute diffs between DAG versions, apply diffs, create partial DAGs from diffs
- **Persistent storage** — LeafStore/ContentStore protocol-based backends with MemoryStore implementations
- **Cross-platform** — builds and tests pass on macOS, iOS, Linux, and Windows

## Requirements

- Swift 5.9+
- Platforms: macOS 12+, iOS 15+, Linux, Windows

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/HORNET-Storage/ScionicMerkleTreeSwift.git", from: "1.0.0"),
]
```

Then add `"ScionicMerkleTree"` as a dependency of your target.

## Usage

### Create a DAG from a directory

```swift
import ScionicMerkleTree

let dag = try createDag(path: "/path/to/directory", timestampRoot: false)
try dag.verify()
try dag.createDirectory(path: "/path/to/output")
```

### Serialize / Deserialize

```swift
// JSON
let jsonData = try dag.toJSON()
let restored = try Dag.fromJSON(jsonData)

// CBOR (binary, more compact)
let cborData = dag.toCBOR()
let restored2 = try Dag.fromCBOR(cborData)

// Read from file
let dag = try Dag.readDag(path: "/path/to/dag.cbor")
```

### Transmission (LeafSync)

```swift
// Individual packets
let packets = dag.getLeafSequence()
for packet in packets {
    try receiver.applyAndVerifyTransmissionPacket(packet)
}

// Batched (size-limited)
let batches = dag.getBatchedLeafSequence()
for batch in batches {
    try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
}
```

### Diffing

```swift
let diff = dagDiff(first: oldDag, second: newDag)
print("Added: \(diff.summary.added), Removed: \(diff.summary.removed)")
let reconstructed = try diff.applyToDAG(oldDag)
```

### Partial DAGs

```swift
let partial = try dag.getPartial(leafHashes: [someHash], pruneLinks: true)
try partial.verify()  // Uses Merkle proofs, doesn't need full tree
```

### DagStore (persistent storage)

```swift
let store = DagStore(dag)
try store.verify()
let content = try store.getContentFromLeaf(fileHash)

// Custom backends
let store = DagStore(root: hash, leafStore: myDB, contentStore: myFileStore)
```

### Parallel creation

```swift
let config = DagBuilderConfig(enableParallel: true, maxWorkers: 4)
let dag = try createDagWithConfig(path: "/large/directory", config: config)
```

## Architecture

```
Sources/ScionicMerkleTree/
├── Internal/             — CBOR, CID, Base encodings, Varint (zero deps)
├── MerkleTree/           — Classic Merkle Tree (ported from go-merkletree)
├── Tree/                 — Key-value Merkle Tree wrapper
├── Dag/                  — Types, leaves, creation, verification, serialization, transmission, store
└── Diff/                 — DAG diffing and patching

Tests/ScionicMerkleTreeTests/
├── CBORTests             — 31 tests
├── CIDTests              — 34 tests (varint, base32, base58, CID)
├── MerkleTreeTests       — 15 tests (build, verify, proofs, 100-leaf)
├── CrossCompatTests      — 5 tests (Merkle tree roots match Go)
├── CrossCompatLeafTests  — 5 tests (leaf CIDs match Go)
├── CrossCompatDagTests   — 1 test (full DAG + verify + recreate)
└── CrossCompatDeepTests  — 1 test (7 files, 4 subdirs, 3 levels)
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 hashing (Apple official, cross-platform) |

**That’s it.** CBOR, CID, multihash, multibase, base58, base32, Merkle trees — all implemented directly in Swift.

## What Remains

The port covers all core functionality. A few secondary items remain:

| Item | Priority | Description |
|------|----------|-------------|
| TransmissionPacket JSON/CBOR serialization | Medium | Serialize individual/batched packets for network transport |
| Test parity with Go | Medium | Go has 15 test files; Swift has 8. Edge cases, serialize round-trip, transmission sim |
| Test fixture system | Low | Go has `testutil/fixtures.go` with 8 pre-built fixtures |
| Streaming verification | Low | Go’s DagStore has `VerifyStreaming` without loading full DAG |

## How Compatibility Works

The Go library hashes leaves by:
1. CBOR-serializing a struct with fields in **exact Go declaration order** (PascalCase keys)
2. Hashing the CBOR bytes with **SHA-256**
3. Wrapping in a **CIDv1** with CBOR codec (`0x51`) and SHA2-256 multihash (`0x12`)
4. Encoding as **base32lower** with `b` prefix

The Swift library reproduces this pipeline byte-for-byte:
- `CBOREncoder` matches `fxamacker/cbor` v2 default encoding
- `CID.generate(from:)` matches `cid.Prefix{Version: 1, Codec: mc.Cbor, MhType: mh.SHA2_256}.Sum()`
- `Base32Lower.encode()` matches `go-multibase` base32lower (no padding)
- `MerkleTree.build()` matches the modified `go-merkletree`

**The same directory produces the same root hash in both Go and Swift.**

## License

MIT
