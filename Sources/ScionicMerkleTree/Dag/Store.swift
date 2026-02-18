// Store.swift — Persistent storage interface for DAG leaves
//
// Ported from dag/store.go.
// Defines LeafStore + ContentStore protocols, DagStore wrapper, DagIndex,
// MemoryLeafStore + MemoryContentStore implementations.

import Foundation

// MARK: - LeafStore Protocol

/// Protocol for persistent leaf storage backends.
public protocol LeafStore {
    func storeLeaf(_ leaf: DagLeaf) throws
    func retrieveLeaf(_ hash: String) throws -> DagLeaf?
    func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf?
    func hasLeaf(_ hash: String) throws -> Bool
    func deleteLeaf(_ hash: String) throws
}

/// Protocol for separate content storage.
public protocol ContentStore {
    func storeContent(_ hash: String, content: Data) throws
    func retrieveContent(_ hash: String) throws -> Data?
    func hasContent(_ hash: String) throws -> Bool
    func deleteContent(_ hash: String) throws
}

/// Optional batch operations for leaf stores.
public protocol BatchLeafStore: LeafStore {
    func storeLeaves(_ leaves: [DagLeaf]) throws
    func retrieveLeaves(_ hashes: [String]) throws -> [String: DagLeaf]
}

/// Optional batch operations for content stores.
public protocol BatchContentStore: ContentStore {
    func storeContents(_ contents: [String: Data]) throws
    func retrieveContents(_ hashes: [String]) throws -> [String: Data]
}

/// Optional interface for efficient leaf counting.
public protocol LeafCounter {
    func count() -> Int
}

/// Optional interface for enumerating all stored leaf hashes.
public protocol LeafEnumerator {
    func getAllLeafHashes() -> [String]
}

// MARK: - DagIndex

/// Lightweight metadata for efficient DAG traversal without loading leaves.
public struct DagIndex {
    /// All leaf hashes in traversal order.
    public var leafHashes: [String] = []
    /// childHash -> [parentHash, ...] for each child.
    public var children: [String: [String]] = [:]
    /// childHash -> parentHash reverse mapping.
    public var parents: [String: String] = [:]
}

// MARK: - DagStore

/// Storage-backed operations for DAGs.
///
/// Mirrors Go's `DagStore`. Wraps LeafStore and optional ContentStore
/// with DAG-level operations: verify, serialize, transmit, labels, partial.
public class DagStore {
    public var root: String
    public var labels: [String: String] = [:]
    public var leafCount: Int = 0

    public let leafStore: LeafStore
    public let contentStore: ContentStore?
    public var separateContent: Bool

    var index: DagIndex?
    var indexBuilt: Bool = false
    private let lock = NSLock()

    // MARK: - Constructors

    /// Creates a DagStore from an in-memory DAG, using MemoryLeafStore.
    public convenience init(_ dag: Dag) {
        let memLeafStore = MemoryLeafStore()
        let memContentStore = MemoryContentStore()

        for (_, leaf) in dag.leafs {
            try? memLeafStore.storeLeaf(leaf)
            if let content = leaf.content {
                try? memContentStore.storeContent(leaf.hash, content: content)
            }
        }

        self.init(root: dag.root, leafStore: memLeafStore, contentStore: memContentStore)

        if let rootLeaf = dag.leafs[dag.root] {
            self.leafCount = rootLeaf.leafCount
        }
    }

    /// Creates a DagStore with explicit stores.
    public init(root: String, leafStore: LeafStore, contentStore: ContentStore? = nil, separateContent: Bool = false) {
        self.root = root
        self.leafStore = leafStore
        self.contentStore = contentStore
        self.separateContent = separateContent
    }

    /// Creates an empty DagStore for receiving transmission packets.
    public static func empty(leafStore: LeafStore? = nil, contentStore: ContentStore? = nil) -> DagStore {
        return DagStore(
            root: "",
            leafStore: leafStore ?? MemoryLeafStore(),
            contentStore: contentStore
        )
    }

    /// Creates a DagStore from a DAG with explicit stores.
    public static func withStorage(_ dag: Dag, leafStore: LeafStore, contentStore: ContentStore? = nil) -> DagStore {
        let store = DagStore(root: dag.root, leafStore: leafStore, contentStore: contentStore)

        for (_, leaf) in dag.leafs {
            try? leafStore.storeLeaf(leaf)
            if let content = leaf.content, let cs = contentStore {
                try? cs.storeContent(leaf.hash, content: content)
            }
        }

        if let rootLeaf = dag.leafs[dag.root] {
            store.leafCount = rootLeaf.leafCount
        }

        return store
    }

    // MARK: - Leaf Access

    public func retrieveLeaf(_ hash: String) throws -> DagLeaf? {
        guard let leaf = try leafStore.retrieveLeaf(hash) else { return nil }

        // Load content from content store if separate
        if leaf.content == nil, let cs = contentStore {
            if let content = try cs.retrieveContent(hash) {
                leaf.content = content
            }
        }
        return leaf
    }

    public func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf? {
        return try leafStore.retrieveLeafWithoutContent(hash)
    }

    public func hasLeaf(_ hash: String) throws -> Bool {
        return try leafStore.hasLeaf(hash)
    }

    public func storeLeaf(_ leaf: DagLeaf) throws {
        try leafStore.storeLeaf(leaf)
        if separateContent, let content = leaf.content, let cs = contentStore {
            try cs.storeContent(leaf.hash, content: content)
        }
    }

    // MARK: - DAG Conversion

    /// Reconstructs a full in-memory Dag from the store.
    public func toDag() throws -> Dag {
        let dag = Dag(root: root)

        func loadLeaf(_ hash: String) throws {
            guard dag.leafs[hash] == nil else { return }
            guard let leaf = try retrieveLeaf(hash) else { return }
            dag.leafs[hash] = leaf
            for childHash in leaf.links {
                try loadLeaf(childHash)
            }
        }

        try loadLeaf(root)
        return dag
    }

    // MARK: - Verification

    /// Verifies the DAG integrity by loading and verifying.
    public func verify() throws {
        let d = try toDag()
        try d.verify()
    }

    /// Verifies a single leaf by hash.
    public func verifyLeaf(_ hash: String) throws {
        guard let leaf = try retrieveLeafWithoutContent(hash) else {
            throw DagError.childMissing(hash)
        }
        if hash == root {
            let d = try toDag()
            try leaf.verifyRootLeaf(dag: d)
        } else {
            try leaf.verifyLeaf()
        }
    }

    // MARK: - Content

    /// Gets full content for a file leaf (assembles from chunks if needed).
    public func getContentFromLeaf(_ hash: String) throws -> Data {
        guard let leaf = try retrieveLeaf(hash) else {
            throw DagError.childMissing(hash)
        }

        if leaf.links.isEmpty {
            return leaf.content ?? Data()
        }

        // Chunked file: assemble from children
        var content = Data()
        // Sort by numeric basename for correct chunk order
        struct ChunkInfo {
            let hash: String
            let itemName: String
        }
        var chunks: [ChunkInfo] = []
        for link in leaf.links {
            if let child = try retrieveLeaf(link) {
                chunks.append(ChunkInfo(hash: link, itemName: child.itemName))
            }
        }
        chunks.sort { a, b in
            let baseA = (a.itemName as NSString).lastPathComponent
            let baseB = (b.itemName as NSString).lastPathComponent
            if let numA = Int(baseA), let numB = Int(baseB) { return numA < numB }
            return a.itemName < b.itemName
        }
        for chunk in chunks {
            if let child = try retrieveLeaf(chunk.hash), let c = child.content {
                content.append(c)
            }
        }
        return content
    }

    // MARK: - Directory Recreation

    /// Recreates directory structure from the store.
    public func createDirectory(path: String) throws {
        let d = try toDag()
        try d.createDirectory(path: path)
    }

    // MARK: - Serialization

    public func toCBOR() throws -> Data {
        let d = try toDag()
        return d.toCBOR()
    }

    public func toJSON() throws -> Data {
        let d = try toDag()
        return try d.toJSON()
    }

    public static func fromCBOR(_ data: Data, leafStore: LeafStore? = nil, contentStore: ContentStore? = nil) throws -> DagStore {
        let d = try Dag.fromCBOR(data)
        return DagStore.withStorage(d, leafStore: leafStore ?? MemoryLeafStore(), contentStore: contentStore)
    }

    public static func fromJSON(_ data: Data, leafStore: LeafStore? = nil, contentStore: ContentStore? = nil) throws -> DagStore {
        let d = try Dag.fromJSON(data)
        return DagStore.withStorage(d, leafStore: leafStore ?? MemoryLeafStore(), contentStore: contentStore)
    }

    // MARK: - Transmission

    /// Adds a transmission packet to the store.
    public func addTransmissionPacket(_ packet: TransmissionPacket) throws {
        // Set root from first packet (root has empty parentHash)
        if packet.parentHash.isEmpty {
            root = packet.leaf.hash
            leafCount = packet.leaf.leafCount
        }

        try storeLeaf(packet.leaf)

        // Establish parent-child link
        if !packet.parentHash.isEmpty {
            if let parent = try leafStore.retrieveLeaf(packet.parentHash) {
                if !parent.hasLink(packet.leaf.hash) {
                    parent.addLink(packet.leaf.hash)
                    try leafStore.storeLeaf(parent)
                }
            }
        }

        // Store proofs
        for (leafHash, proof) in packet.proofs {
            // Find the parent that has this child link
            // For now, store proofs on the leaf's parent
            if let parent = try leafStore.retrieveLeaf(packet.parentHash) {
                parent.proofs[leafHash] = proof
                try leafStore.storeLeaf(parent)
            }
        }
    }

    /// Gets transmission packets (delegates to Dag).
    public func getLeafSequence() throws -> [TransmissionPacket] {
        let d = try toDag()
        return d.getLeafSequence()
    }

    // MARK: - Partial DAG

    /// Creates a partial DAG from the store.
    public func getPartial(leafHashes: [String], pruneLinks: Bool) throws -> Dag {
        let d = try toDag()
        return try d.getPartial(leafHashes: leafHashes, pruneLinks: pruneLinks)
    }

    // MARK: - Labels

    public func calculateLabels() throws {
        let d = try toDag()
        try d.calculateLabels()
        labels = d.labels
    }

    public func getHashesByLabelRange(start: Int, end: Int) throws -> [String] {
        if labels.isEmpty { try calculateLabels() }
        var hashes: [String] = []
        for i in start...end {
            guard let hash = labels["\(i)"] else {
                throw DagError.brokenDag("label \(i) not found")
            }
            hashes.append(hash)
        }
        return hashes
    }

    public func getLabel(hash: String) throws -> String {
        if hash == root { return "0" }
        if labels.isEmpty { try calculateLabels() }
        for (label, labelHash) in labels {
            if labelHash == hash { return label }
        }
        throw DagError.childMissing(hash)
    }

    // MARK: - Batch Operations

    /// Stores multiple leaves in batch.
    public func storeLeavesInBatches(_ leaves: [DagLeaf]) throws {
        if let batchStore = leafStore as? BatchLeafStore {
            try batchStore.storeLeaves(leaves)
        } else {
            for leaf in leaves {
                try storeLeaf(leaf)
            }
        }
    }
}

// MARK: - MemoryLeafStore

/// In-memory LeafStore implementation.
public class MemoryLeafStore: LeafStore, BatchLeafStore, LeafCounter, LeafEnumerator {
    private var leaves: [String: DagLeaf] = [:]
    private let lock = NSLock()

    public init() {}

    public func storeLeaf(_ leaf: DagLeaf) throws {
        lock.lock(); defer { lock.unlock() }
        leaves[leaf.hash] = leaf
    }

    public func retrieveLeaf(_ hash: String) throws -> DagLeaf? {
        lock.lock(); defer { lock.unlock() }
        return leaves[hash]?.clone()
    }

    public func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf? {
        lock.lock(); defer { lock.unlock() }
        guard let leaf = leaves[hash]?.clone() else { return nil }
        leaf.content = nil
        return leaf
    }

    public func hasLeaf(_ hash: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return leaves[hash] != nil
    }

    public func deleteLeaf(_ hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        leaves.removeValue(forKey: hash)
    }

    public func storeLeaves(_ leaves: [DagLeaf]) throws {
        lock.lock(); defer { lock.unlock() }
        for leaf in leaves { self.leaves[leaf.hash] = leaf }
    }

    public func retrieveLeaves(_ hashes: [String]) throws -> [String: DagLeaf] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: DagLeaf] = [:]
        for hash in hashes {
            if let leaf = leaves[hash] { result[hash] = leaf.clone() }
        }
        return result
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return leaves.count
    }

    public func getAllLeafHashes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(leaves.keys)
    }

    public func getAllLeaves() -> [String: DagLeaf] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: DagLeaf] = [:]
        for (k, v) in leaves { result[k] = v }
        return result
    }
}

// MARK: - MemoryContentStore

/// In-memory ContentStore implementation.
public class MemoryContentStore: ContentStore, BatchContentStore {
    private var contents: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func storeContent(_ hash: String, content: Data) throws {
        lock.lock(); defer { lock.unlock() }
        contents[hash] = content
    }

    public func retrieveContent(_ hash: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return contents[hash]
    }

    public func hasContent(_ hash: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return contents[hash] != nil
    }

    public func deleteContent(_ hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        contents.removeValue(forKey: hash)
    }

    public func storeContents(_ contents: [String: Data]) throws {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in contents { self.contents[k] = v }
    }

    public func retrieveContents(_ hashes: [String]) throws -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Data] = [:]
        for hash in hashes {
            if let content = contents[hash] { result[hash] = content }
        }
        return result
    }
}
