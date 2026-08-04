// Types.swift — Core DAG types
//
// Ported from dag/types.go. All primary data structures for the Scionic Merkle Tree.

import Foundation

// MARK: - Chunk Size Configuration

/// Default chunk size for file processing (2MB).
public let defaultChunkSize = 2048 * 1024

/// Current fixed chunk size, used by the LEGACY fixed-size mode only (after
/// `setChunkSize` / `disableChunking`). Under the default fastcdc-v1 mode
/// boundaries are content-defined and this value is not consulted.
/// Set to -1 to disable chunking (entire files become single chunks).
public var chunkSize = defaultChunkSize

/// Sets the chunk size for file processing and switches the producer to the
/// LEGACY fixed-size chunking mode. fastcdc-v1 stays off until
/// `setDefaultChunkSize` restores it. (Mirrors Go's `SetChunkSize`.)
public func setChunkSize(_ size: Int) {
    chunkingFastCDC = false
    chunkSize = size
}

/// Disables chunking entirely (files processed as single chunks) — a legacy
/// fixed-mode variant, so fastcdc-v1 is switched off too.
public func disableChunking() {
    setChunkSize(-1)
}

/// Restores the DEFAULT chunking behavior: fastcdc-v1 content-defined
/// chunking, with `chunkSize` reset for any legacy reader of it.
/// (Mirrors Go's `SetDefaultChunkSize`, which assigns both fields directly —
/// routing through `setChunkSize` would clear the fastcdc flag again.)
public func setDefaultChunkSize() {
    chunkingFastCDC = true
    chunkSize = defaultChunkSize
}

// MARK: - Batch Size Configuration

/// Default batch size for transmission packets (4MB).
public let defaultBatchSize = 4 * 1024 * 1024

/// Current batch size for batched transmission.
public var batchSize = defaultBatchSize

public func setBatchSize(_ size: Int) {
    batchSize = size
}

public func disableBatching() {
    setBatchSize(-1)
}

public func setDefaultBatchSize() {
    setBatchSize(defaultBatchSize)
}

// MARK: - Leaf Type

/// The type of a leaf in the Scionic Merkle Tree.
public enum LeafType: String, Codable, Equatable {
    case file = "file"
    case chunk = "chunk"
    case directory = "directory"
}

// MARK: - Leaf Processor

/// Generates custom metadata for a leaf during DAG creation.
/// Called for each file/directory entry (except root, which uses `additionalData` directly).
public typealias LeafProcessor = (
    _ path: String,
    _ relPath: String,
    _ isDir: Bool,
    _ isRoot: Bool,
    _ leafType: LeafType
) -> [String: String]?

// MARK: - Dag

/// The top-level Scionic Merkle Tree structure.
public class Dag {
    /// CID hash of the root leaf.
    public var root: String
    /// All leaves keyed by their CID hash.
    public var leafs: [String: DagLeaf]
    /// Label → leaf hash mapping (excludes root which is always "0").
    public var labels: [String: String]

    public init(root: String = "", leafs: [String: DagLeaf] = [:], labels: [String: String] = [:]) {
        self.root = root
        self.leafs = leafs
        self.labels = labels
    }

    /// Returns true if this DAG has fewer leaves than the root's LeafCount indicates.
    public func isPartial() -> Bool {
        guard let rootLeaf = leafs[root] else { return true }
        if rootLeaf.leafCount == 0 { return false }
        return leafs.count < rootLeaf.leafCount
    }
}

// MARK: - DagLeaf

/// A single node in the Scionic Merkle Tree.
public class DagLeaf {
    /// CID hash of this leaf (generated from CBOR-serialized fields).
    public var hash: String = ""
    /// File/directory name (relative path component).
    public var itemName: String = ""
    /// Type: file, chunk, or directory.
    public var type: LeafType = .file
    /// SHA-256 hash of the content bytes.
    public var contentHash: Data? = nil
    /// Raw file content (may be nil if stored externally).
    public var content: Data? = nil
    /// Classic Merkle Tree root of child link hashes.
    public var classicMerkleRoot: Data = Data()
    /// Expected number of child links (included in hash for tamper-proofing).
    public var currentLinkCount: Int = 0
    /// Total leaves in entire DAG (root leaf only).
    public var leafCount: Int = 0
    /// Total content size in bytes (root leaf only).
    public var contentSize: Int64 = 0
    /// Total serialized DAG size in bytes (root leaf only).
    public var dagSize: Int64 = 0
    /// Ordered list of child CID hashes.
    public var links: [String] = []
    /// CID hash of the parent leaf.
    public var parentHash: String = ""
    /// Arbitrary metadata (included in hash, sorted by key before hashing).
    public var additionalData: [String: String] = [:]
    /// Classic Merkle Tree instance (transient, not serialized).
    public var merkleTree: MerkleTree? = nil
    /// Leaf map for the Classic Merkle Tree (transient, not serialized).
    public var leafMap: [String: DataBlock]? = nil
    /// Stored Merkle proofs for partial DAG verification.
    public var proofs: [String: ClassicTreeBranch] = [:]

    public init() {}

    /// Checks if this leaf has a link to the given hash.
    public func hasLink(_ hash: String) -> Bool {
        return links.contains(hash)
    }

    /// Adds a link to the given hash.
    public func addLink(_ hash: String) {
        links.append(hash)
    }

    /// Creates a fully independent copy of this leaf.
    ///
    /// Unlike Go's `Clone()` -- which shares the `Content` backing array and
    /// documents that callers must reassign it rather than write through it --
    /// every field copied here is a value type: `Data`, `[String]`,
    /// `[String: String]`, and `[String: ClassicTreeBranch]` (whose `Proof`
    /// is itself a struct of `[Data]` + `UInt32`). Copy-on-write makes the
    /// copy both free and safe: nothing written to the copy can reach the
    /// original, and no bytes are duplicated until someone actually writes.
    ///
    /// `merkleTree` and `leafMap` are deliberately left nil. They are
    /// transient derived state rebuilt from `links` on demand, and Go marks
    /// the same two fields `json:"-"` and omits them from `Clone()` too.
    public func clone() -> DagLeaf {
        let c = DagLeaf()
        c.hash = hash
        c.itemName = itemName
        c.type = type
        c.contentHash = contentHash
        c.content = content
        c.classicMerkleRoot = classicMerkleRoot
        c.currentLinkCount = currentLinkCount
        c.leafCount = leafCount
        c.contentSize = contentSize
        c.dagSize = dagSize
        c.links = links
        c.parentHash = parentHash
        c.additionalData = additionalData
        // merkleTree and leafMap are transient, not cloned
        c.proofs = proofs
        return c
    }

    /// Returns approximate serialized size without full CBOR encoding.
    ///
    /// Mirrors Go's `EstimateSize()`. Used by batched transmission to decide batch boundaries.
    public func estimateSize() -> Int {
        var size = 0
        size += hash.utf8.count                          // Hash (~64 bytes)
        size += itemName.utf8.count                      // ItemName
        size += type.rawValue.utf8.count                 // Type (~10 bytes)
        size += content?.count ?? 0                      // Content
        size += contentHash?.count ?? 0                  // ContentHash (32 if present)
        size += classicMerkleRoot.count                  // ClassicMerkleRoot (32 if present)
        size += links.count * 64                         // Links (each ~64 byte CID)
        for (key, value) in additionalData {
            size += key.utf8.count + value.utf8.count     // AdditionalData
        }
        for (_, proof) in proofs {
            size += 10 * 32                               // ~10 siblings per proof, 32 bytes each
            _ = proof // suppress unused warning
        }
        size += 32                                        // Integer fields overhead
        size += 100                                       // Struct + CBOR encoding overhead
        return size
    }

    /// Sets a label on this leaf (used by label management).
    public func setLabel(_ label: String) {
        // Labels are managed at the Dag level, but this provides API compat with Go
        // In Go, this modifies the hash to include the label, but in practice
        // labels are stored in Dag.labels, not on the leaf itself
    }
}

// MARK: - DagLeafBuilder

/// Temporary builder for constructing DagLeaf instances.
public class DagLeafBuilder {
    public var itemName: String
    public var label: Int64 = 0
    public var leafType: LeafType = .file
    public var data: Data? = nil
    public var links: [String] = []

    public init(name: String) {
        self.itemName = name
    }

    public func setType(_ type: LeafType) {
        self.leafType = type
    }

    public func setData(_ data: Data) {
        self.data = data
    }

    public func addLink(_ hash: String) {
        self.links.append(hash)
    }
}

// MARK: - DagBuilder

/// Temporary builder for constructing the full DAG.
public class DagBuilder {
    public var leafs: [String: DagLeaf] = [:]
    private let lock = NSLock()

    public init() {}

    /// Adds a leaf to the builder (not thread-safe).
    public func addLeaf(_ leaf: DagLeaf, parent: DagLeaf?) {
        addLeafInternal(leaf, parent: parent)
    }

    /// Adds a leaf to the builder (thread-safe).
    public func addLeafSafe(_ leaf: DagLeaf, parent: DagLeaf?) {
        lock.lock()
        defer { lock.unlock() }
        addLeafInternal(leaf, parent: parent)
    }

    private func addLeafInternal(_ leaf: DagLeaf, parent: DagLeaf?) {
        if let parent = parent {
            if !parent.hasLink(leaf.hash) {
                parent.addLink(leaf.hash)
            }
            // Rebuild classic merkle tree if parent has > 1 link
            if parent.links.count > 1 {
                let builder = TreeContent()
                for link in parent.links {
                    builder.addLeaf(key: link, data: link)
                }
                if let (merkleTree, leafMap) = try? builder.build() {
                    parent.merkleTree = merkleTree
                    parent.leafMap = leafMap
                    parent.classicMerkleRoot = merkleTree.root
                }
            }
        }
        leafs[leaf.hash] = leaf
    }

    /// Builds the final Dag from the accumulated leaves.
    public func buildDag(root: String) -> Dag {
        return Dag(root: root, leafs: leafs)
    }
}

// MARK: - ClassicTreeBranch

/// A Classic Merkle Tree proof for a single child link within a parent leaf.
public struct ClassicTreeBranch {
    /// The leaf data (CID hash string).
    public var leaf: String
    /// The Merkle proof.
    public var proof: Proof

    public init(leaf: String = "", proof: Proof = Proof()) {
        self.leaf = leaf
        self.proof = proof
    }
}

// MARK: - DagBranch

/// A leaf plus its path to the root with Merkle proofs.
public struct DagBranch {
    public var leaf: DagLeaf
    public var path: [DagLeaf]
    public var merkleProofs: [String: ClassicTreeBranch]

    public init(leaf: DagLeaf, path: [DagLeaf] = [], merkleProofs: [String: ClassicTreeBranch] = [:]) {
        self.leaf = leaf
        self.path = path
        self.merkleProofs = merkleProofs
    }
}

// MARK: - TransmissionPacket

/// A single leaf with its parent hash and Merkle proofs for LeafSync transmission.
public struct TransmissionPacket {
    public var leaf: DagLeaf
    public var parentHash: String
    public var proofs: [String: ClassicTreeBranch]

    public init(leaf: DagLeaf, parentHash: String = "", proofs: [String: ClassicTreeBranch] = [:]) {
        self.leaf = leaf
        self.parentHash = parentHash
        self.proofs = proofs
    }
}

// MARK: - BatchedTransmissionPacket

/// A batch of leaves with relationship metadata for efficient transmission.
public struct BatchedTransmissionPacket {
    public var leaves: [DagLeaf]
    public var relationships: [String: String]  // childHash -> parentHash
    public var packetIndex: Int
    public var totalPackets: Int

    public init(leaves: [DagLeaf] = [], relationships: [String: String] = [:],
                packetIndex: Int = 0, totalPackets: Int = 0) {
        self.leaves = leaves
        self.relationships = relationships
        self.packetIndex = packetIndex
        self.totalPackets = totalPackets
    }
}

// MARK: - DagBuilderConfig

/// Configuration for DAG building behavior.
public struct DagBuilderConfig {
    /// Enable parallel processing of files and directories.
    public var enableParallel: Bool
    /// Max concurrent workers (0 = auto-detect, -1 = unlimited).
    public var maxWorkers: Int
    /// Add timestamp to root leaf's additional data.
    public var timestampRoot: Bool
    /// Additional data to attach to the root leaf.
    public var additionalData: [String: String]
    /// Custom leaf processor callback.
    public var processor: LeafProcessor?

    public init(
        enableParallel: Bool = false,
        maxWorkers: Int = 0,
        timestampRoot: Bool = false,
        additionalData: [String: String] = [:],
        processor: LeafProcessor? = nil
    ) {
        self.enableParallel = enableParallel
        self.maxWorkers = maxWorkers
        self.timestampRoot = timestampRoot
        self.additionalData = additionalData
        self.processor = processor
    }

    /// Default sequential configuration.
    public static func defaultConfig() -> DagBuilderConfig {
        return DagBuilderConfig()
    }

    /// Default parallel configuration (auto-detect workers).
    public static func parallelConfig() -> DagBuilderConfig {
        return DagBuilderConfig(enableParallel: true)
    }

    /// Parallel configuration with specific worker count.
    public static func parallelConfig(workers: Int) -> DagBuilderConfig {
        return DagBuilderConfig(enableParallel: true, maxWorkers: workers)
    }
}
