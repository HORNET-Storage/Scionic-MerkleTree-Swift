// Store.swift — Persistent storage interface for DAG leaves
//
// Ported from dag/store.go.
// Defines LeafStore + ContentStore protocols, DagStore wrapper, DagIndex,
// MemoryLeafStore + MemoryContentStore implementations.

import Foundation

// MARK: - LeafStore Protocol

/// Protocol for persistent leaf storage backends.
///
/// **Ownership contract:** every `retrieve*` method must return a leaf the
/// caller owns and may mutate freely. `DagLeaf` is a class, so returning a
/// live reference into the store's own storage lets callers write straight
/// through into the store -- outside the lock, and outside the
/// content-preservation merge in `storeLeaf`. `DagStore.retrieveLeaf`
/// depends on this contract directly: it assigns `leaf.content` on whatever
/// the store hands back. `MemoryLeafStore` honours it by cloning on every
/// read; conforming stores must do the same.
public protocol LeafStore {
    func storeLeaf(_ leaf: DagLeaf) throws
    /// Returns a leaf the caller owns. Must not alias the store's storage.
    func retrieveLeaf(_ hash: String) throws -> DagLeaf?
    /// Returns a content-stripped leaf the caller owns. Must not alias the
    /// store's storage -- stripping content from a live reference would erase
    /// the stored content as a side effect.
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
    /// Returns leaves the caller owns. Must not alias the store's storage.
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

/// Optional interface for stores that cache childHash -> parentHash relationships.
public protocol RelationshipCache {
    func getCachedRelationships() -> [String: String]?
}

// MARK: - DagIndex

/// Lightweight metadata for efficient DAG traversal without loading leaves.
public struct DagIndex {
    /// All leaf hashes in traversal order.
    public var leafHashes: [String]
    /// parentHash -> child hashes.
    public var children: [String: [String]]
    /// childHash -> parentHash reverse mapping.
    public var parents: [String: String]

    public init(
        leafHashes: [String] = [],
        children: [String: [String]] = [:],
        parents: [String: String] = [:]
    ) {
        self.leafHashes = leafHashes
        self.children = children
        self.parents = parents
    }
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

    public func deleteLeaf(_ hash: String) throws {
        try leafStore.deleteLeaf(hash)
        if hash == root {
            root = ""
            leafCount = 0
        }
    }

    public func storeLeaf(_ leaf: DagLeaf) throws {
        try leafStore.storeLeaf(leaf)
        if separateContent, let content = leaf.content, let cs = contentStore {
            try cs.storeContent(leaf.hash, content: content)
        }
    }

    public func setRoot(_ rootHash: String) throws {
        lock.lock()
        root = rootHash
        lock.unlock()

        if let rootLeaf = try retrieveLeafWithoutContent(rootHash) {
            lock.lock()
            leafCount = rootLeaf.leafCount
            lock.unlock()
        }
    }

    /// Builds an in-memory traversal index using cached relationships when available.
    public func buildIndex() throws {
        guard !root.isEmpty else {
            throw DagError.brokenDag("no root set")
        }

        lock.lock()
        defer { lock.unlock() }

        if let cache = leafStore as? RelationshipCache,
           let relationships = cache.getCachedRelationships() {
            try buildIndexFromCache(relationships)
            return
        }

        try buildIndexByTraversal()
    }

    private func buildIndexFromCache(_ relationships: [String: String]) throws {
        var newIndex = DagIndex()

        for (childHash, parentHash) in relationships {
            newIndex.parents[childHash] = parentHash
            if !parentHash.isEmpty {
                newIndex.children[parentHash, default: []].append(childHash)
            }
        }

        var visited = Set<String>()
        var queue = [root]
        var cursor = 0

        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            if visited.contains(current) { continue }
            visited.insert(current)
            newIndex.leafHashes.append(current)

            var children = newIndex.children[current] ?? []
            children.sort()
            newIndex.children[current] = children
            for childHash in children where !visited.contains(childHash) {
                queue.append(childHash)
            }
        }

        if let rootLeaf = try leafStore.retrieveLeafWithoutContent(root) {
            leafCount = rootLeaf.leafCount
        }

        index = newIndex
        indexBuilt = true
    }

    private func buildIndexByTraversal() throws {
        var newIndex = DagIndex()
        var visited = Set<String>()
        var queue: [(hash: String, parentHash: String)] = [(root, "")]
        var cursor = 0

        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            if visited.contains(current.hash) { continue }
            visited.insert(current.hash)

            guard let leaf = try leafStore.retrieveLeafWithoutContent(current.hash) else {
                continue
            }

            newIndex.leafHashes.append(current.hash)
            newIndex.parents[current.hash] = current.parentHash

            if !leaf.links.isEmpty {
                let children = leaf.links
                newIndex.children[current.hash] = children
                for childHash in children where !visited.contains(childHash) {
                    queue.append((childHash, current.hash))
                }
            }

            if current.hash == root {
                leafCount = leaf.leafCount
            }
        }

        index = newIndex
        indexBuilt = true
    }

    public func hasIndex() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return indexBuilt
    }

    public func getIndex() -> DagIndex? {
        lock.lock(); defer { lock.unlock() }
        return index
    }

    public func clearIndex() {
        lock.lock(); defer { lock.unlock() }
        index = nil
        indexBuilt = false
    }

    public func addToIndex(leafHash: String, parentHash: String, children: [String]) {
        lock.lock(); defer { lock.unlock() }

        if index == nil {
            index = DagIndex()
        }

        guard index?.leafHashes.contains(leafHash) == false else { return }

        index?.leafHashes.append(leafHash)
        index?.parents[leafHash] = parentHash
        if !children.isEmpty {
            index?.children[leafHash] = children
        }
    }

    public func markIndexBuilt() {
        lock.lock(); defer { lock.unlock() }
        indexBuilt = true
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

    /// Verifies DAG integrity through the storage-backed API.
    public func verifyStreaming() throws {
        guard !root.isEmpty else {
            throw DagError.brokenDag("no root set")
        }

        if try isPartialStreaming() {
            try verifyWithProofsStreaming()
        } else {
            try verifyFullDagStreaming()
        }
    }

    private func isPartialStreaming() throws -> Bool {
        guard let rootLeaf = try retrieveLeafWithoutContent(root) else { return true }
        if let counter = leafStore as? LeafCounter {
            return counter.count() < rootLeaf.leafCount
        }
        // Count every existing leaf reachable from root; fewer than the root's
        // leafCount means the DAG is partial.
        let hashes = try collectExistingLeafHashesFromRoot()
        return hashes.count < rootLeaf.leafCount
    }

    private func verifyFullDagStreaming() throws {
        guard let rootLeaf = try retrieveLeafWithoutContent(root) else {
            throw DagError.childMissing(root)
        }
        try rootLeaf.verifyRootLeaf()
        if rootLeaf.links.count == rootLeaf.currentLinkCount && rootLeaf.currentLinkCount > 0 {
            try verifyChildrenAgainstMerkleRootStreaming(rootLeaf)
        }
        var visited: Set<String> = [root]
        try verifyChildrenFullDagStreaming(parent: rootLeaf, visited: &visited)
    }

    private func verifyChildrenFullDagStreaming(parent: DagLeaf, visited: inout Set<String>) throws {
        if parent.currentLinkCount > 0 && parent.links.count == parent.currentLinkCount {
            try verifyChildrenAgainstMerkleRootStreaming(parent)
        }

        for childHash in parent.links {
            if visited.contains(childHash) { continue }
            visited.insert(childHash)
            guard let childLeaf = try retrieveLeafWithoutContent(childHash) else {
                throw DagError.childMissing(childHash)
            }
            try childLeaf.verifyLeaf()
            guard parent.hasLink(childHash) else {
                throw DagError.brokenDag("parent \(parent.hash) does not contain link to child \(childHash)")
            }
            try verifyChildrenFullDagStreaming(parent: childLeaf, visited: &visited)
        }
    }

    private func verifyWithProofsStreaming() throws {
        guard let rootLeaf = try retrieveLeafWithoutContent(root) else {
            throw DagError.childMissing(root)
        }
        try rootLeaf.verifyRootLeaf()

        if rootLeaf.currentLinkCount > 0 {
            var childrenInDag = 0
            for childHash in rootLeaf.links {
                if try hasLeaf(childHash) { childrenInDag += 1 }
            }

            if childrenInDag == rootLeaf.currentLinkCount && rootLeaf.links.count == rootLeaf.currentLinkCount {
                try verifyChildrenAgainstMerkleRootStreaming(rootLeaf)
            } else if rootLeaf.currentLinkCount == 1 {
                if childrenInDag > 0, let childHash = rootLeaf.links.first,
                   rootLeaf.classicMerkleRoot != Data(childHash.utf8) {
                    throw DagError.brokenDag("single child verification failed: ClassicMerkleRoot does not match child hash")
                }
            } else if rootLeaf.proofs.isEmpty && childrenInDag < rootLeaf.currentLinkCount {
                throw DagError.brokenDag("root has \(rootLeaf.currentLinkCount) links but only \(childrenInDag) children exist in DAG (no proofs available)")
            }
        }

        let leafHashes = try collectAllLeafHashesForPartialDag()
        for leafHash in leafHashes where leafHash != root {
            guard let leaf = try retrieveLeafWithoutContent(leafHash) else { continue }
            try leaf.verifyLeaf()
            try verifyPathToRootStreaming(leaf)
        }
    }

    private func verifyPathToRootStreaming(_ leaf: DagLeaf) throws {
        var current = leaf
        while current.hash != root {
            guard let parent = try findParentStreaming(childHash: current.hash) else {
                throw DagError.brokenDag("broken path to root for leaf \(leaf.hash)")
            }
            if parent.hash != root {
                try parent.verifyLeaf()
            }

            let hasAllChildren = parent.links.count == parent.currentLinkCount
            if hasAllChildren && parent.currentLinkCount > 0 {
                var childrenInDag = 0
                for childHash in parent.links {
                    if try hasLeaf(childHash) { childrenInDag += 1 }
                }
                if childrenInDag == parent.currentLinkCount {
                    try verifyChildrenAgainstMerkleRootStreaming(parent)
                } else {
                    try verifyWithProofStreaming(parent: parent, childHash: current.hash)
                }
            } else if parent.currentLinkCount > 1 {
                try verifyWithProofStreaming(parent: parent, childHash: current.hash)
            }

            current = parent
        }
    }

    private func verifyWithProofStreaming(parent: DagLeaf, childHash: String) throws {
        guard let proof = parent.proofs[childHash] else {
            throw DagError.brokenDag("missing merkle proof for node \(childHash) in partial DAG")
        }
        try parent.verifyBranch(proof)
    }

    private func findParentStreaming(childHash: String) throws -> DagLeaf? {
        // Pick the lowest-hash parent that links this child. Store enumeration
        // order is unspecified, so a chunk shared by several parents used to
        // resolve to an arbitrary one and its proof lookup could miss at random.
        let leafHashes = try collectAllLeafHashesForPartialDag()
        var best: DagLeaf? = nil
        for hash in leafHashes {
            guard let leaf = try retrieveLeafWithoutContent(hash) else { continue }
            guard leaf.hasLink(childHash) else { continue }
            if best == nil || leaf.hash < best!.hash {
                best = leaf
            }
        }
        return best
    }

    private func collectAllLeafHashesForPartialDag() throws -> [String] {
        if let enumerator = leafStore as? LeafEnumerator {
            return enumerator.getAllLeafHashes()
        }
        return try collectExistingLeafHashesFromRoot()
    }

    private func collectExistingLeafHashesFromRoot() throws -> [String] {
        guard !root.isEmpty else {
            throw DagError.brokenDag("no root set")
        }
        var visited = Set<String>()
        var hashes: [String] = []

        func collect(_ hash: String) throws {
            guard !visited.contains(hash) else { return }
            guard try leafStore.hasLeaf(hash) else { return }
            visited.insert(hash)
            hashes.append(hash)
            guard let leaf = try retrieveLeafWithoutContent(hash) else { return }
            for childHash in leaf.links {
                try collect(childHash)
            }
        }

        try collect(root)
        return hashes
    }

    private func verifyChildrenAgainstMerkleRootStreaming(_ parent: DagLeaf) throws {
        if parent.currentLinkCount == 0 { return }

        if parent.currentLinkCount == 1 {
            if let childHash = parent.links.first,
               parent.classicMerkleRoot != Data(childHash.utf8) {
                throw DagError.brokenDag("single child merkle root mismatch")
            }
            return
        }

        let builder = TreeContent()
        for linkHash in parent.links {
            builder.addLeaf(key: linkHash, data: linkHash)
        }
        let (tree, _) = try builder.build()
        if tree.root != parent.classicMerkleRoot {
            throw DagError.brokenDag("merkle root mismatch for parent \(parent.hash)")
        }
    }

    /// Verifies a single leaf by hash.
    public func verifyLeaf(_ hash: String) throws {
        guard let leaf = try retrieveLeafWithoutContent(hash) else {
            throw DagError.childMissing(hash)
        }
        if hash == root {
            try leaf.verifyRootLeaf()
        } else {
            try leaf.verifyLeaf()
        }
    }

    /// Verifies a child leaf and its relationship to a parent leaf.
    public func verifyLeafWithParent(_ leafHash: String, parentHash: String, proof: ClassicTreeBranch? = nil) throws {
        guard let leaf = try retrieveLeafWithoutContent(leafHash) else {
            throw DagError.childMissing(leafHash)
        }
        guard let parent = try retrieveLeafWithoutContent(parentHash) else {
            throw DagError.childMissing(parentHash)
        }
        guard parent.hasLink(leafHash) else {
            throw DagError.brokenDag("parent \(parentHash) does not link to child \(leafHash)")
        }

        if leafHash == root {
            try leaf.verifyRootLeaf()
        } else {
            try leaf.verifyLeaf()
        }

        if parent.currentLinkCount > 1 {
            guard let proof = proof else {
                throw DagError.brokenDag("proof required for child \(leafHash) under parent \(parentHash)")
            }
            try parent.verifyBranch(proof)
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

    /// Gets full content through metadata-first store access.
    public func getContentFromLeafStreaming(_ hash: String) throws -> Data {
        guard let leaf = try retrieveLeafWithoutContent(hash) else {
            throw DagError.childMissing(hash)
        }

        if leaf.links.isEmpty {
            let full = try retrieveLeaf(hash)
            if let full { try verifyLeafContentHash(full) }
            return full?.content ?? Data()
        }

        struct ChunkInfo {
            let hash: String
            let itemName: String
        }

        var chunks: [ChunkInfo] = []
        for link in leaf.links {
            guard let child = try retrieveLeafWithoutContent(link) else {
                throw DagError.childMissing(link)
            }
            chunks.append(ChunkInfo(hash: link, itemName: child.itemName))
        }

        chunks.sort { a, b in
            let baseA = (a.itemName as NSString).lastPathComponent
            let baseB = (b.itemName as NSString).lastPathComponent
            if let numA = Int(baseA), let numB = Int(baseB) { return numA < numB }
            return a.itemName < b.itemName
        }

        var content = Data()
        for chunk in chunks {
            guard let child = try retrieveLeaf(chunk.hash) else {
                throw DagError.childMissing(chunk.hash)
            }
            try verifyLeafContentHash(child)
            content.append(child.content ?? Data())
        }
        return content
    }

    // MARK: - Directory Recreation

    /// Recreates directory structure from the store.
    public func createDirectory(path: String) throws {
        let d = try toDag()
        try d.createDirectory(path: path)
    }

    /// Recreates directory structure using storage-backed traversal.
    public func createDirectoryStreaming(path: String) throws {
        guard let rootLeaf = try retrieveLeafWithoutContent(root) else {
            throw DagError.childMissing(root)
        }
        try createDirectoryLeafStreaming(rootLeaf, path: path)
    }

    private func createDirectoryLeafStreaming(_ leaf: DagLeaf, path: String) throws {
        switch leaf.type {
        case .directory:
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            for childHash in leaf.links {
                guard let child = try retrieveLeafWithoutContent(childHash) else {
                    throw DagError.childMissing(childHash)
                }
                let childPath = try safeJoin(path, child.itemName)
                try createDirectoryLeafStreaming(child, path: childPath)
            }
        case .file:
            let content = try getContentFromLeafStreaming(leaf.hash)
            let parentPath = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
            try content.write(to: URL(fileURLWithPath: path))
        case .chunk:
            throw DagError.brokenDag("unexpected chunk leaf at path: \(path)")
        }
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
        if packet.parentHash.isEmpty {
            try packet.leaf.verifyRootLeaf()
            packet.leaf.parentHash = ""
            try storeLeaf(packet.leaf)

            lock.lock()
            root = packet.leaf.hash
            leafCount = packet.leaf.leafCount
            lock.unlock()
            return
        }

        try packet.leaf.verifyLeaf()

        if let parent = try retrieveLeafWithoutContent(packet.parentHash) {
            guard parent.hasLink(packet.leaf.hash) else {
                throw DagError.brokenDag("parent \(packet.parentHash) does not link to child \(packet.leaf.hash)")
            }

            if parent.currentLinkCount > 1 {
                guard let proof = packet.proofs[packet.leaf.hash] else {
                    throw DagError.brokenDag("missing merkle proof for leaf \(packet.leaf.hash)")
                }
                try parent.verifyBranch(proof)
            }
        }

        packet.leaf.parentHash = packet.parentHash
        try storeLeaf(packet.leaf)

        if !packet.proofs.isEmpty, let parent = try leafStore.retrieveLeaf(packet.parentHash) {
            for (leafHash, proof) in packet.proofs {
                parent.proofs[leafHash] = proof
            }
            try leafStore.storeLeaf(parent)
        }
    }

    /// Adds a batched transmission packet to the store.
    ///
    /// Every leaf must carry an explicit relationship entry. An empty parent is the root
    /// sentinel and is accepted only while the store has no root (or re-sends the same
    /// root); a missing entry or a conflicting root claim is rejected, so no leaf can be
    /// stored without taking a verification branch (missing and empty relationships were
    /// previously conflated and fell through to storage unverified).
    public func addBatchedTransmissionPacket(_ packet: BatchedTransmissionPacket?) throws {
        guard let packet, !packet.leaves.isEmpty else { return }

        var verifiedLeaves: [DagLeaf] = []
        for leaf in packet.leaves {
            guard let parentHash = packet.relationships[leaf.hash] else {
                throw DagError.brokenDag("missing relationship for leaf \(leaf.hash)")
            }
            if parentHash.isEmpty {
                guard root.isEmpty || root == leaf.hash else {
                    throw DagError.brokenDag("unexpected extra root marker for leaf \(leaf.hash)")
                }
                try leaf.verifyRootLeaf()
                leaf.parentHash = ""
                root = leaf.hash
                leafCount = leaf.leafCount
            } else {
                try leaf.verifyLeaf()
                leaf.parentHash = parentHash
                if let parent = try retrieveLeafWithoutContent(parentHash), !parent.hasLink(leaf.hash) {
                    throw DagError.brokenDag("parent \(parentHash) does not link to child \(leaf.hash)")
                }
            }
            verifiedLeaves.append(leaf)
        }

        try storeLeavesInBatches(verifiedLeaves)
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

    public func iterateDagStreaming(_ processLeaf: (DagLeaf, DagLeaf?) throws -> Void) throws {
        guard !root.isEmpty else { return }
        var visited = Set<String>()

        func visit(_ hash: String, parent: DagLeaf?) throws {
            guard !visited.contains(hash) else { return }
            guard let leaf = try retrieveLeafWithoutContent(hash) else {
                throw DagError.childMissing(hash)
            }
            visited.insert(hash)
            try processLeaf(leaf, parent)
            for childHash in leaf.links {
                try visit(childHash, parent: leaf)
            }
        }

        try visit(root, parent: nil)
    }

    public func iterateDagWithIndex(_ processLeaf: (String, String) throws -> Void) throws {
        guard !root.isEmpty else {
            throw DagError.brokenDag("no root set")
        }

        if !hasIndex() || getIndex() == nil {
            try buildIndex()
        }

        guard let currentIndex = getIndex() else {
            throw DagError.brokenDag("index not built")
        }

        for leafHash in currentIndex.leafHashes {
            try processLeaf(leafHash, currentIndex.parents[leafHash] ?? "")
        }
    }

    public func countLeavesStreaming() throws -> Int {
        if root.isEmpty { return 0 }
        if let currentIndex = getIndex(), hasIndex(), !currentIndex.leafHashes.isEmpty {
            return currentIndex.leafHashes.count
        }
        if leafCount > 0 { return leafCount }
        if let rootLeaf = try retrieveLeafWithoutContent(root), rootLeaf.leafCount > 0 {
            return rootLeaf.leafCount
        }
        if let counter = leafStore as? LeafCounter {
            return counter.count()
        }

        var count = 0
        try iterateDagStreaming { _, _ in
            count += 1
        }
        return count
    }

    public func updateParentHashesStreaming(batchSize: Int = 10) throws {
        guard !root.isEmpty else {
            throw DagError.brokenDag("no root set")
        }

        if !hasIndex() || getIndex() == nil {
            try buildIndex()
        }

        guard let currentIndex = getIndex() else {
            throw DagError.brokenDag("index not built")
        }

        let effectiveBatchSize = batchSize > 0 ? batchSize : 10
        var batch: [DagLeaf] = []
        batch.reserveCapacity(effectiveBatchSize)

        for leafHash in currentIndex.leafHashes {
            guard let leaf = try retrieveLeafWithoutContent(leafHash) else { continue }
            leaf.parentHash = currentIndex.parents[leafHash] ?? ""
            batch.append(leaf)

            if batch.count >= effectiveBatchSize {
                try storeLeavesInBatches(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try storeLeavesInBatches(batch)
        }
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

    private func storeLeafUnlocked(_ leaf: DagLeaf) {
        if leaf.content == nil, let existingContent = leaves[leaf.hash]?.content {
            let merged = leaf.clone()
            merged.content = existingContent
            leaves[leaf.hash] = merged
        } else {
            leaves[leaf.hash] = leaf
        }
    }

    public func storeLeaf(_ leaf: DagLeaf) throws {
        lock.lock(); defer { lock.unlock() }
        storeLeafUnlocked(leaf)
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
        for leaf in leaves { storeLeafUnlocked(leaf) }
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

    /// Returns every stored leaf as an owned copy.
    ///
    /// Clones for the same reason every other read on this store clones:
    /// `DagLeaf` is a class, so handing out the stored instance would let a
    /// caller mutate the store's contents in place -- outside the lock, and
    /// outside the content-preservation merge in `storeLeafUnlocked`.
    public func getAllLeaves() -> [String: DagLeaf] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: DagLeaf] = [:]
        for (k, v) in leaves { result[k] = v.clone() }
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
