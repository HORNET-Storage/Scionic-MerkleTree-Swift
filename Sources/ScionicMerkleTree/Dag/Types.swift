// Types.swift — Core DAG types
//
// Ported from dag/types.go. All primary data structures for the Scionic Merkle Tree.

import Foundation

// MARK: - Chunk Size Configuration

/// Default chunk size for file processing (2MB).
public let defaultChunkSize = 2048 * 1024

/// Current chunk size. Files larger than this are split into chunks.
/// Set to -1 to disable chunking (entire files become single chunks).
public var chunkSize = defaultChunkSize

/// Sets the chunk size for file processing.
public func setChunkSize(_ size: Int) {
    chunkSize = size
}

/// Disables chunking entirely (files processed as single chunks).
public func disableChunking() {
    setChunkSize(-1)
}

/// Resets to default chunk size (2MB).
public func setDefaultChunkSize() {
    setChunkSize(defaultChunkSize)
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
        guard let rootLeaf = leafs[root] else { return false }
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

    /// Creates a deep copy of this leaf.
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
                // This will be handled properly in TreeContent (Task #13)
                // For now, just track that the tree needs rebuilding
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
