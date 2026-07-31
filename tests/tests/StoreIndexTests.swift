import Foundation
import XCTest
@testable import ScionicMerkleTree

final class StoreIndexTests: XCTestCase {
    func testBuildIndexMatchesDagRelationships() throws {
        let dag = try makeIndexedDag()
        let store = DagStore(dag)

        XCTAssertFalse(store.hasIndex())
        try store.buildIndex()

        let index = try XCTUnwrap(store.getIndex())
        XCTAssertTrue(store.hasIndex())
        XCTAssertEqual(index.leafHashes.first, dag.root)
        XCTAssertEqual(Set(index.leafHashes), Set(dag.leafs.keys))
        XCTAssertEqual(index.parents[dag.root] ?? "", "")

        for leaf in dag.leafs.values {
            XCTAssertEqual(index.children[leaf.hash] ?? [], leaf.links, leaf.itemName)
            for childHash in leaf.links {
                XCTAssertEqual(index.parents[childHash], leaf.hash, childHash)
            }
        }
    }

    func testIterateDagWithIndexBuildsAndReturnsParentHashes() throws {
        let dag = try makeIndexedDag()
        let store = DagStore(dag)
        var visited: [(hash: String, parentHash: String)] = []

        try store.iterateDagWithIndex { leafHash, parentHash in
            visited.append((leafHash, parentHash))
        }

        XCTAssertTrue(store.hasIndex())
        XCTAssertEqual(visited.first?.hash, dag.root)
        XCTAssertEqual(Set(visited.map { $0.hash }), Set(dag.leafs.keys))
        XCTAssertEqual(visited.first?.parentHash, "")
    }

    func testManualIndexLifecycle() throws {
        let store = DagStore.empty()

        store.addToIndex(leafHash: "root", parentHash: "", children: ["a", "b"])
        store.addToIndex(leafHash: "a", parentHash: "root", children: [])
        store.addToIndex(leafHash: "a", parentHash: "root", children: [])
        store.markIndexBuilt()

        let index = try XCTUnwrap(store.getIndex())
        XCTAssertTrue(store.hasIndex())
        XCTAssertEqual(index.leafHashes, ["root", "a"])
        XCTAssertEqual(index.parents["a"], "root")
        XCTAssertEqual(index.children["root"] ?? [], ["a", "b"])

        store.clearIndex()
        XCTAssertFalse(store.hasIndex())
        XCTAssertNil(store.getIndex())
    }

    func testUpdateParentHashesStreamingUsesIndexAndPreservesContent() throws {
        let dag = try makeIndexedDag()
        let leafStore = MemoryLeafStore()
        for leaf in dag.leafs.values {
            let clone = leaf.clone()
            clone.parentHash = ""
            try leafStore.storeLeaf(clone)
        }

        let store = DagStore(root: dag.root, leafStore: leafStore)
        store.leafCount = dag.leafs[dag.root]?.leafCount ?? dag.leafs.count
        let contentLeaf = try XCTUnwrap(dag.leafs.values.first { $0.content != nil })

        try store.updateParentHashesStreaming(batchSize: 2)
        let index = try XCTUnwrap(store.getIndex())

        for leafHash in index.leafHashes {
            let leaf = try XCTUnwrap(try leafStore.retrieveLeaf(leafHash))
            XCTAssertEqual(leaf.parentHash, index.parents[leafHash] ?? "")
        }

        let preserved = try XCTUnwrap(try leafStore.retrieveLeaf(contentLeaf.hash))
        XCTAssertEqual(preserved.content, contentLeaf.content)
    }

    func testBuildIndexUsesCachedRelationshipsWhenAvailable() throws {
        let dag = try makeIndexedDag()
        let leafStore = CachedRelationshipLeafStore(
            leaves: dag.leafs,
            relationships: relationshipMap(for: dag)
        )
        let store = DagStore(root: dag.root, leafStore: leafStore)

        try store.buildIndex()

        let index = try XCTUnwrap(store.getIndex())
        XCTAssertEqual(index.leafHashes.first, dag.root)
        XCTAssertEqual(Set(index.leafHashes), Set(dag.leafs.keys))
        XCTAssertEqual(leafStore.retrieveLeafCalls, 0)
        XCTAssertLessThanOrEqual(leafStore.retrieveLeafWithoutContentCalls, 1)
    }

    /// The store index has to land on the same parent the decode path does.
    ///
    /// A shared chunk has several parents, so "the" parent of that leaf is only
    /// well defined if every code path picks the same one. `fromSerializable`
    /// pins it to the LOWEST parent hash; the store index used to record
    /// whichever parent BFS reached FIRST. The identical DAG therefore reported a
    /// different `parentHash` depending on whether it had been decoded or loaded
    /// from a store — and nothing on the wire ever contradicted that, because
    /// `parentHash` is absent from `SerializableDagLeaf`.
    ///
    /// The root is a FILE leaf on purpose. `buildLeaf` sorts links only for
    /// DIRECTORY leaves, so listing the higher parent first survives into the
    /// root's links and BFS genuinely reaches the higher parent first. With a
    /// directory root the links would be sorted by hash, BFS would arrive at the
    /// lowest parent anyway, and this test would pass against the very bug it
    /// exists to catch.
    ///
    /// Mirrors Go's `TestStoreIndexPicksTheLowestParentForASharedChunk` and
    /// Rust's `store_index_picks_the_lowest_parent_for_a_shared_chunk`.
    func testStoreIndexPicksTheLowestParentForASharedChunk() throws {
        func build(
            _ name: String,
            _ type: LeafType,
            data: Data? = nil,
            links: [String] = []
        ) throws -> DagLeaf {
            let builder = DagLeafBuilder(name: name)
            builder.setType(type)
            if let data = data {
                builder.setData(data)
            }
            for link in links {
                builder.addLink(link)
            }
            return try builder.buildLeaf(additionalData: nil)
        }

        let shared = try build("0", .chunk, data: Data("shared".utf8))
        let extraA = try build("1", .chunk, data: Data("extra-a".utf8))
        let extraB = try build("2", .chunk, data: Data("extra-b".utf8))
        let parentA = try build("a.bin", .file, links: [shared.hash, extraA.hash])
        let parentB = try build("b.bin", .file, links: [shared.hash, extraB.hash])
        let lower = parentA.hash < parentB.hash ? parentA : parentB
        let higher = parentA.hash < parentB.hash ? parentB : parentA
        let root = try build("root", .file, links: [higher.hash, lower.hash])

        let leaves = [shared, extraA, extraB, lower, higher, root]
        let dag = Dag(
            root: root.hash,
            leafs: Dictionary(uniqueKeysWithValues: leaves.map { ($0.hash, $0) })
        )

        // Vacuity guards. Without these the assertions below can hold for
        // reasons that have nothing to do with the rule under test.
        XCTAssertEqual(
            root.links,
            [higher.hash, lower.hash],
            "the fixture no longer lists the higher parent first; BFS would reach "
                + "the lowest parent first and this test would prove nothing"
        )
        let sharedParents = leaves.filter { $0.links.contains(shared.hash) }
        XCTAssertEqual(
            sharedParents.count,
            2,
            "expected the shared chunk to have exactly two parents, got "
                + "\(sharedParents.map { $0.hash })"
        )

        let leafStore = MemoryLeafStore()
        for leaf in leaves {
            try leafStore.storeLeaf(leaf.clone())
        }
        let store = DagStore(root: dag.root, leafStore: leafStore)
        try store.buildIndex()
        let index = try XCTUnwrap(store.getIndex())

        XCTAssertEqual(
            index.parents[shared.hash],
            lower.hash,
            "the store index chose the wrong parent for the shared chunk; BFS "
                + "reaches \(higher.hash) first, which is what it used to record"
        )

        // The store index and the deserialization path must agree, leaf for leaf.
        let decoded = try Dag.fromCBOR(dag.toCBOR())
        for (hash, leaf) in decoded.leafs where hash != decoded.root {
            XCTAssertEqual(
                index.parents[hash],
                leaf.parentHash,
                "leaf \(hash): the store index and deserialization disagree"
            )
        }

        // updateParentHashesStreaming persists whatever the index decided, so it
        // has to land on the same answer rather than re-deriving its own.
        try store.updateParentHashesStreaming(batchSize: 2)
        let stored = try XCTUnwrap(try leafStore.retrieveLeaf(shared.hash))
        XCTAssertEqual(stored.parentHash, lower.hash)
    }

    private func makeIndexedDag() throws -> Dag {
        let root = try ParityTestHelpers.makeTempDir("store_index")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        return try createDag(path: root)
    }

    private func relationshipMap(for dag: Dag) -> [String: String] {
        var relationships = [dag.root: ""]
        for leaf in dag.leafs.values {
            for childHash in leaf.links {
                relationships[childHash] = leaf.hash
            }
        }
        return relationships
    }
}

private final class CachedRelationshipLeafStore: LeafStore, RelationshipCache {
    private var leaves: [String: DagLeaf]
    private let relationships: [String: String]?
    private(set) var retrieveLeafCalls = 0
    private(set) var retrieveLeafWithoutContentCalls = 0

    init(leaves: [String: DagLeaf], relationships: [String: String]?) {
        var cloned: [String: DagLeaf] = [:]
        for (hash, leaf) in leaves {
            cloned[hash] = leaf.clone()
        }
        self.leaves = cloned
        self.relationships = relationships
    }

    func getCachedRelationships() -> [String: String]? {
        return relationships
    }

    func storeLeaf(_ leaf: DagLeaf) throws {
        leaves[leaf.hash] = leaf.clone()
    }

    func retrieveLeaf(_ hash: String) throws -> DagLeaf? {
        retrieveLeafCalls += 1
        return leaves[hash]?.clone()
    }

    func retrieveLeafWithoutContent(_ hash: String) throws -> DagLeaf? {
        retrieveLeafWithoutContentCalls += 1
        guard let leaf = leaves[hash]?.clone() else { return nil }
        leaf.content = nil
        return leaf
    }

    func hasLeaf(_ hash: String) throws -> Bool {
        return leaves[hash] != nil
    }

    func deleteLeaf(_ hash: String) throws {
        leaves.removeValue(forKey: hash)
    }
}
