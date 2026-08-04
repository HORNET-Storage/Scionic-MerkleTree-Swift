# Scionic Merkle Trees (Swift)

A comprehensive Swift port of [Scionic-Merkle-Tree](https://github.com/HORNET-Storage/Scionic-Merkle-Tree) — a hybrid Merkle DAG / Merkle Tree data structure that combines the folder support of IPFS Merkle DAGs with the small branches of Classic Merkle Trees.

**Proven byte-identical with the Go implementation** — 18 cross-compatibility tests verify that Swift produces the exact same CID hashes as Go for the same input, from individual leaves to full multi-level directory DAGs, backed by a further 25 Go-parity tests covering spec vectors, fixture roots, transmission packets and fastcdc-v1 conformance.

**Chunking**: new trees default to **fastcdc-v1 content-defined chunking** (min 512 KiB / target 2 MiB / max 8 MiB) — boundaries follow content, so an edit re-chunks only its neighborhood instead of shifting every fixed slice after it. Roots cut this way carry `"chunking": "fastcdc-v1"` in their additional data; the legacy fixed-size cutter stays available via `setChunkSize`, and verification never re-chunks, so both kinds of trees verify everywhere. The port was written for cross-implementation compatibility: Go, Rust and Swift cut bit-identical chunks for identical bytes on every platform — proven by the conformance manifest committed under `spec/fastcdc-vectors` — so content deduplicates no matter which implementation or OS produced it.

## What’s Ported

This is a near-complete port of the Go library. **25 source files, 294 tests, 0 skipped.** CI runs the full suite on every push across Windows (CNG/BCrypt hashing), Linux (swift-crypto/BoringSSL), and macOS (CryptoKit).

### Core (fully ported)

| Go File | Swift File | Status | Description |
|---------|-----------|--------|-------------|
| `dag/types.go` | `src/dag/Types.swift` | ✅ Complete | All types: Dag, DagLeaf, DagBuilder, DagLeafBuilder, ClassicTreeBranch, DagBranch, TransmissionPacket, BatchedTransmissionPacket, DagBuilderConfig, LeafType, LeafProcessor |
| `dag/leaves.go` | `src/dag/Leaves.swift` | ✅ Complete | BuildLeaf, BuildRootLeaf, VerifyLeaf, VerifyRootLeaf (standalone root CID verification plus full-DAG ContentSize/DagSize validation), VerifyChildrenAgainstMerkleRoot, GetBranch, VerifyBranch, HasLink, AddLink, Clone, EstimateSize |
| `dag/dag.go` | `src/dag/DagCreation.swift` + `src/dag/DagVerification.swift` + `src/dag/ChunkOrder.swift` + `src/dag/ParentIndex.swift` | ✅ Complete | CreateDag, CreateDagAdvanced, CreateDagCustom, CreateDagWithConfig, true chunked file reads, parallel creation (DispatchQueue worker pool), Verify (full + partial with Merkle proofs), IterateDag, CreateDirectory, GetContentFromLeaf, GetPartial, CalculateLabels, GetHashesByLabelRange, GetLabel, IsPartial, chunkIndexFromItemName / compareChunkItemNames, minimumParentIndex |
| `dag/fastcdc.go` + `dag/fastcdc_gear.go` | `src/dag/FastCDC.swift` | ✅ Complete | fastcdc-v1 content-defined chunking (the default mode): frozen gear table + seed derivation, normative boundary loop, mode dispatch, streaming cutter with an 8 MiB window, public `cutChunks`, root chunking tag |
| `dag/serialize.go` | `src/dag/Serialization.swift` | ✅ Complete | ToJSON, FromJSON, ToCBOR, FromCBOR, ReadDag, ToSerializable, FromSerializable (rebuilds Merkle trees + parent hashes). Both formats are written from one shared wire tree, so field names and order cannot drift between them |
| `dag/transmission.go` | `src/dag/Transmission.swift` | ✅ Complete | GetLeafSequence (BFS with proofs), VerifyTransmissionPacket, ApplyTransmissionPacket, ApplyAndVerifyTransmissionPacket, RemoveAllContent, GetBatchedLeafSequence (size-limited batches), VerifyBatchedTransmissionPacket, ApplyBatchedTransmissionPacket, BatchedTransmissionPacket.GetRootLeaf |
| `dag/store.go` | `src/dag/Store.swift` | ✅ Complete | LeafStore, ContentStore, batch/count/enumerator/cache protocols, DagStore verification/streaming verification without full DAG materialization, index build/cache/iterate/update-parent-hash APIs, MemoryLeafStore + MemoryContentStore |
| `dag/utils.go` | `src/dag/Utils.swift` | ✅ Complete | SortMapByKeys, SortMapForVerification, KeyValue, CalculateTotalContentSize, CalculateTotalDagSize |
| `diff/diff.go` | `src/diff/Diff.swift` | ✅ Complete | Diff, DiffFromNewLeaves, GetAddedLeaves, GetRemovedLeaves, ApplyToDAG, CreatePartialDag |
| `merkletree/merkletree.go` | `src/classic-merkle-tree/*.swift` | ✅ Complete | Full Classic Merkle Tree: build from map, proof generation, proof verification, configurable hash function, OpenZeppelin-compatible sorting, parallel leaf hashing, parent hashing, and proof updates via `runInParallel` + `numRoutines`, GetIndexForKey |
| `tree/tree.go` | `src/classic-tree-wrapper/TreeContent.swift` | ✅ Complete | TreeContent, TreeLeaf, Build, VerifyTree, VerifyRoot |

### Internal (implemented from scratch, no external deps)

| Component | Swift File | What it replaces |
|-----------|-----------|------------------|
| CBOR Encoder/Decoder | `src/internal/CBOR.swift` | `fxamacker/cbor/v2` — deterministic encoding matching Go’s defaults |
| SHA-256 backend | `src/internal/SHA256Backend.swift` | swift-crypto's portable-C fallback on Windows — the default hash path is CNG/`BCryptHashData` there (9.4× raw throughput); Apple and Linux delegate to swift-crypto |
| Wire JSON writer | `src/internal/WireJSON.swift` | `encoding/json` (`MarshalIndent`) — Go’s exact indentation, escaping and separators, written from the same wire tree the CBOR encoder reads |
| Wire JSON parser | `src/internal/WireJSONParser.swift` + `WireJSONSchema.swift` | `encoding/json` (`Unmarshal`) — order-preserving parse plus a schema-directed walk back into that wire tree |
| CID Generation | `src/internal/CID.swift` | `go-cid` + `go-multihash` + `go-multicodec` — CIDv1 with CBOR codec (0x51) + SHA2-256 |
| Base32lower | `src/internal/BaseEncoding.swift` | `go-multibase` — RFC 4648 lowercase, no padding |
| Base58btc | `src/internal/BaseEncoding.swift` | `mr-tron/base58` — Bitcoin-style encoding |
| Varint | `src/internal/Varint.swift` | `go-varint` — unsigned LEB128 |

## Cross-Compatibility Proof

**18 cross-compatibility tests** (`tests/tests/crosscompat/`) verify byte-identical output between Go and Swift at every level of the stack:

| Layer | Test | Verified |
|-------|------|----------|
| Classic Merkle Tree | 2-, 3- and 5-leaf trees, plus CID-like keys | Root hashes + proof paths + siblings match |
| Individual leaf hashing | file, chunk, directory leaves | CID strings match |
| Leaf with content | SHA-256 content hash | CID matches |
| Leaf with metadata | AdditionalData map | CID matches |
| Full DAG (manual) | 2 files + root directory | Root hash + child hashes + LeafCount + ContentSize + DagSize match |
| Full DAG (filesystem) | 3 files + 1 subdir | Root hash matches, verify passes, directory recreation matches |
| **Deep directory** | **7 files, 4 subdirs, 3 levels deep** | **All 12 leaf hashes match, verify passes, all file contents recreated correctly** |
| Wire format | Go skeleton and selected-leaf vectors, batched packet shape | Decodes and verifies against golden Go bytes; legacy counter-free packets stay decodable |

A further **25 Go-parity tests** sit outside that directory: `SpecVectorParityTests` (9) walks the shared spec-vector corpus — committed under `spec/vectors` and byte-identical across the Go, Rust, and Swift repositories — `TransmissionParityTests` (9) covers packet flows, `FixtureRootParityTests` (3) pins the standard fixture roots, and `FastCDCVectorTests` (4) rebuilds the fastcdc-v1 conformance manifest committed under `spec/fastcdc-vectors`: chunk boundaries, chunk digests, edit-reuse partitions, DAG root CIDs and the root chunking tag, all against the values Go generated.

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

### JSON is byte-identical too

Both wire formats are written from one shared wire tree: the JSON writer
reproduces Go's `MarshalIndent` output exactly (field names, declaration
order, indentation, escaping, `null` for absent optionals), and the CBOR
encoder reads the same tree, so the two formats cannot drift apart. There are
deliberately **no `Codable` conformances** — reaching for `JSONEncoder` would
silently emit a document no other port reads. Read back, JSON goes through
this port's own order-preserving parser and a schema-directed walk into that
same tree.

The corpus commits a `.json` sibling for every `.cbor` artifact, and every
port asserts per artifact that re-encoding reproduces the committed JSON bytes
*and* that the value decoded from JSON re-encodes to the committed CBOR bytes —
which is what makes the two decoders provably equivalent rather than merely each
self-consistent. One case, `json_metadata_probe`, carries `AdditionalData` keys
of lengths 1, 8 and 9: the only input class that can distinguish CBOR's
length-first key order from JSON's plain bytewise order, and therefore the only
vector in the corpus that can fail for that reason.

## Performance

Measured on Windows (Swift 6.3.1, 24 CPUs) against the Go reference and the
Rust port: same 18.25 MiB corpus, 256 KiB chunks, min of 15 samples, all three
harnesses back to back in one session. Every harness prints its DAG root and
encoded sizes first, and all three match at every chunk size, so the timings
compare equal work. The same session is recorded from the Rust side in the
Rust repository's README. Go is the anchor column; lower is better:

| Workload | Swift | Go | Rust | Swift vs Go |
|---|---:|---:|---:|---|
| `create_sequential` | 53.48 ms | 15.80 ms | 18.66 ms | 3.4× slower |
| `create_parallel` | 9.66 ms | 4.80 ms | 3.46 ms | 2.0× slower |
| `verify` | 17.44 ms | 10.93 ms | 5.02 ms | 1.6× slower |
| `to_cbor` | 9.95 ms | 3.57 ms | 4.71 ms | 2.8× slower |
| `from_cbor` | **3.02 ms** | 3.16 ms | 3.09 ms | parity |
| `to_json` | 81.38 ms | 79.75 ms | 67.09 ms | parity |
| `from_json` | 61.43 ms | 70.78 ms | 48.29 ms | **1.15× faster** |
| `leaf_sequence` | **0.32 ms** | 2.79 ms | 2.63 ms | **8.7× faster** |
| `batched_sequence` | 0.291 ms | 0.089 ms | 0.102 ms | 3.3× slower |

`from_cbor` and `leaf_sequence` lead all three ports, and `from_json` is ahead
of Go. Implementation notes behind the hot paths:

- **SHA-256 on Windows goes through CNG/BCrypt**
  (`src/internal/SHA256Backend.swift`). swift-crypto's vendored BoringSSL ships
  only `__ELF__`/`__APPLE__` assembly, so on Windows its SHA-256 runs as
  portable C: 449 MB/s against 4,199 MB/s through `BCryptHashData` on the same
  machine — 9.4× one-shot, and BCrypt is faster at every input size down to
  64 B (287 ns vs 515 ns per hash). Apple and Linux delegate to swift-crypto,
  which on Apple platforms re-exports CryptoKit and is already
  hardware-accelerated.
- **The CBOR encoder writes into one exactly pre-sized `[UInt8]` buffer**
  (`CBOREncoder.encodedSize` mirrors the encoder case for case) instead of
  growing a `Data` incrementally.
- **Default Merkle pair hashing streams both siblings into one hasher**
  instead of concatenating them into a fresh buffer per pair.
- **`getLeafSequence` builds each parent's proof tree once per parent** rather
  than once per child, which is why it leads both other ports.

Two honest caveats. The Windows Swift 6.3.1 toolchain ships a standard library
built `+assertions` — a cost the Go and Rust toolchains do not carry, and
`-c release` cannot remove from the stdlib — so some share of the
create/verify gap is toolchain rather than port. And Windows is a proxy for
the production target: the encoder/allocation characteristics are expected to
transfer to iOS, the BCrypt backend does not exist there (Apple builds hash
through CryptoKit), and absolute iOS numbers remain unmeasured until the
suite runs on a device. CI does run the full suite on Linux and macOS as
well, so both non-Windows hash backends are exercised on every push.

## Features

- **Directory support** — entire directory trees become Scionic Merkle DAGs, like IPFS
- **Small Merkle branches** — logarithmic proof sizes via Classic Merkle Trees inside parent leaves
- **Content-defined chunking (fastcdc-v1)** — the default: boundaries follow content, so edits re-chunk only their neighborhood; byte-identical across Go, Rust and Swift, with the legacy fixed cutter still available via `setChunkSize`
- **LeafSync** — numbered leaves with label-based range queries for synchronization
- **Streaming I/O** — files are read with `FileHandle` chunks; fastcdc streams through one reusable 8 MiB window per file
- **Storage-backed verification** — `DagStore.verifyStreaming()` verifies via metadata-first store access without calling `toDag()`
- **Indexed storage traversal** — cache-backed `DagIndex` APIs support fast parent/child traversal and parent-hash updates
- **Parallel creation** — `createDagWithConfig` with `enableParallel: true` uses DispatchQueue worker pools
- **Parallel classic trees** — `MerkleTreeConfig(runInParallel:numRoutines:)` parallelizes leaf and parent-node hashing
- **Verification** — full DAG verification + partial DAG verification with stored Merkle proofs
- **ContentSize/DagSize validation** — root leaf recalculates and verifies sizes from children when a full DAG is available
- **Serialization** — JSON and CBOR, both byte-identical to Go; one shared wire tree feeds both writers, and both parsers feed it back
- **Transmission** — individual and size-limited batched packets; current batches carry deterministic packet counters for bounded sliding-window transports, while legacy counter-free packets remain decodable
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
    .package(url: "https://github.com/HORNET-Storage/Scionic-MerkleTree-Swift.git", from: "2.4.3"),
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

### Chunking

fastcdc-v1 content-defined chunking is the default: boundaries follow content
(min 512 KiB / target 2 MiB / max 8 MiB), so inserting bytes into a large file
re-chunks only the edited neighborhood instead of shifting every fixed slice
after it. Roots cut this way carry `"chunking": "fastcdc-v1"` in their
additional data; an absent tag means legacy fixed-size chunks. Verification
never re-chunks, so trees cut by either mode verify everywhere.

```swift
// Default: fastcdc-v1 content-defined chunking
let dag = try createDag(path: "/path/to/directory", timestampRoot: false)

// Pin the legacy fixed-size cutter (what the spec-vector corpus pins)
setChunkSize(defaultChunkSize)
defer { setDefaultChunkSize() } // restore fastcdc-v1

// Chunk in-memory content exactly the way the DAG builders do
let chunks = cutChunks(data)
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

// Batched (size-limited, with PacketIndex/TotalPackets transport metadata)
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
src/
├── dag/                  — Scionic DAG types, leaves, creation, fastcdc-v1 + legacy chunking, verification, serialization, transmission, store
├── diff/                 — DAG diffing and patching
├── internal/             — CBOR, CID, SHA-256 backend, Base encodings, Varint
├── classic-merkle-tree/  — Classic Merkle Tree proof generation/verification
├── classic-tree-wrapper/ — Key/value wrapper around Classic Merkle Trees
├── testutil/             — Fixture builders used by parity tests
└── ScionicMerkleTree.swift

tests/
├── diff/                 — DAG diff/apply tests
├── classic-tree-wrapper/ — Go tree wrapper parity tests
├── tests/                — Go-style integration, DAG, partial, store, store-index, streaming, transmission, fixture, cross-compat, and fastcdc unit + conformance tests
├── AuditTests.swift      — clone, serialization, store, transmission, diff, partial flows
├── AuditSecurityTests.swift — path-traversal rejection, streaming tamper detection, forged-child detection
├── FixtureTests.swift    — standard fixture coverage across DAG operations
├── MerkleTreeTests.swift — classic Merkle Tree build/verify/proof behavior, including parallel/sequential parity
├── TreeContentTests.swift — Classic tree wrapper parity for build and verify helpers
├── CBORTests.swift       — CBOR encoding/decoding determinism
├── CIDTests.swift        — varint, base32, base58, CID generation
└── ScionicMerkleTreeTests.swift — package smoke test

spec/
├── vectors/          — shared spec-vector corpus, byte-identical across the Go, Rust and Swift repos
└── fastcdc-vectors/  — fastcdc-v1 conformance manifest (boundaries, chunk digests, reuse partitions, DAG roots)
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 hashing on Apple platforms (a CryptoKit re-export there) and Linux; Windows builds hash through the OS's CNG/BCrypt via `src/internal/SHA256Backend.swift` instead |

**That’s it.** CBOR, CID, multihash, multibase, base58, base32, Merkle trees — all implemented directly in Swift.

## What Remains

Remaining work is ongoing hardening rather than known missing core behavior:

| Item | Priority | Description |
|------|----------|-------------|
| Broader Go parity sweep | Low | Continue adding edge-case vectors as the Go implementation evolves |
| Backend-specific integration tests | Low | Exercise custom persistent LeafStore/ContentStore implementations beyond the in-memory stores |

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
