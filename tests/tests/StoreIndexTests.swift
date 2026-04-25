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
