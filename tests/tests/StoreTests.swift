import Foundation
import XCTest
@testable import ScionicMerkleTree

final class StoreTests: XCTestCase {
    func testDagStoreBasic() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)

        XCTAssertEqual(store.root, dag.root)
        XCTAssertEqual(store.leafCount, dag.leafs[dag.root]?.leafCount)
        XCTAssertTrue(try store.hasLeaf(dag.root))
        XCTAssertNotNil(try store.retrieveLeaf(dag.root))
    }

    func testDagStoreVerify() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)
        try store.verify()
        try store.verifyLeaf(dag.root)
    }

    func testDagStoreToDag() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)
        let restored = try store.toDag()
        ParityTestHelpers.assertSameLeafSet(restored, dag)
        try restored.verify()
    }

    func testDagStoreCreateDirectory() throws {
        let root = try ParityTestHelpers.makeTempDir("store_create_source")
        try ParityTestHelpers.createBasicDirectory(at: root)
        let dag = try createDag(path: root)
        let output = try ParityTestHelpers.makeTempDir("store_create_output")

        try DagStore(dag).createDirectory(path: output)
        XCTAssertEqual(try String(contentsOfFile: ParityTestHelpers.join(output, "README.md"), encoding: .utf8), "# Basic\n")
        XCTAssertEqual(try String(contentsOfFile: ParityTestHelpers.join(output, "docs", "guide.txt"), encoding: .utf8), "guide content\n")
    }

    func testDagStoreWithSeparateContent() throws {
        let dag = try makeStoreDag()
        let leafStore = MemoryLeafStore()
        let contentStore = MemoryContentStore()

        for leaf in dag.leafs.values {
            let clone = leaf.clone()
            if let content = clone.content {
                try contentStore.storeContent(clone.hash, content: content)
                clone.content = nil
            }
            try leafStore.storeLeaf(clone)
        }

        let store = DagStore(root: dag.root, leafStore: leafStore, contentStore: contentStore, separateContent: true)
        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file))
        let retrieved = try XCTUnwrap(store.retrieveLeaf(fileLeaf.hash))
        XCTAssertEqual(retrieved.content, fileLeaf.content)
        try store.verify()
    }

    /// Configuring a content store must actually take the payload *out* of the
    /// metadata store, not copy it into both.
    ///
    /// This routes through `DagStore.storeLeaf` instead of splitting by hand the
    /// way the test above does — that manual split is exactly what was papering
    /// over the gap. Go's `StoreLeaf` and Rust's `store_leaf` strip here; Swift
    /// wrote the payload to the content store *and* left it inline, so a store
    /// configured to keep bytes out of the metadata layer held two copies instead
    /// of none.
    func testSeparateContentIsRemovedFromTheMetadataStore() throws {
        let dag = try makeStoreDag()
        let leafStore = MemoryLeafStore()
        let contentStore = MemoryContentStore()
        let store = DagStore(
            root: dag.root,
            leafStore: leafStore,
            contentStore: contentStore,
            separateContent: true
        )

        for leaf in dag.leafs.values {
            try store.storeLeaf(leaf)
        }

        // Vacuity guard: with no payload in the fixture there is nothing to
        // misplace and every assertion below would be free.
        let carrier = try XCTUnwrap(
            dag.leafs.values.first { ($0.content?.isEmpty == false) },
            "the fixture carries no payload, so this test would prove nothing"
        )

        XCTAssertTrue(
            try contentStore.hasContent(carrier.hash),
            "the payload never reached the content store"
        )
        let metadataOnly = try XCTUnwrap(try leafStore.retrieveLeaf(carrier.hash))
        XCTAssertNil(
            metadataOnly.content,
            "the payload was written to both stores; the metadata store exists to stay small"
        )

        // ...and it still reads back whole through the DagStore.
        let rejoined = try XCTUnwrap(try store.retrieveLeaf(carrier.hash))
        XCTAssertEqual(rejoined.content, carrier.content)
        try store.verify()
    }

    func testDagStoreWithOptions() throws {
        let dag = try makeStoreDag()
        let leafStore = MemoryLeafStore()
        let contentStore = MemoryContentStore()
        let store = DagStore.withStorage(dag, leafStore: leafStore, contentStore: contentStore)

        XCTAssertEqual(store.root, dag.root)
        XCTAssertTrue(try leafStore.hasLeaf(dag.root))
        XCTAssertTrue(try contentStore.hasContent(try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file)).hash))
    }

    func testDagStoreIterateDag() throws {
        let dag = try makeStoreDag()
        let restored = try DagStore(dag).toDag()
        var visited: [String] = []
        try restored.iterateDag { leaf, _ in
            visited.append(leaf.hash)
        }
        XCTAssertEqual(Set(visited), Set(dag.leafs.keys))
    }

    func testDagStoreLabels() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)
        try store.calculateLabels()
        XCTAssertEqual(store.labels.count, dag.leafs.count - 1)
        let childHash = try XCTUnwrap(store.labels["1"])
        XCTAssertEqual(try store.getLabel(hash: childHash), "1")
        XCTAssertFalse(try store.getHashesByLabelRange(start: 1, end: 2).isEmpty)
    }

    func testDagStoreSerialization() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)

        let cborStore = try DagStore.fromCBOR(try store.toCBOR())
        XCTAssertEqual(cborStore.root, dag.root)
        try cborStore.verify()

        let jsonStore = try DagStore.fromJSON(try store.toJSON())
        XCTAssertEqual(jsonStore.root, dag.root)
        try jsonStore.verify()
    }

    func testDagStoreTransmissionPackets() throws {
        let dag = try makeStoreDag()
        let sender = DagStore(dag)
        let receiver = DagStore.empty()

        for packet in try sender.getLeafSequence() {
            try receiver.addTransmissionPacket(packet)
        }

        let received = try receiver.toDag()
        ParityTestHelpers.assertSameLeafSet(received, dag)
        try received.verify()
    }

    func testDagStoreGetPartial() throws {
        let dag = try makeStoreDag()
        let target = try XCTUnwrap(dag.leafs[dag.root]?.links.first)
        let partial = try DagStore(dag).getPartial(leafHashes: [target], pruneLinks: true)
        XCTAssertTrue(partial.isPartial())
        XCTAssertNotNil(partial.leafs[target])
        try partial.verify()
    }

    func testMemoryLeafStoreConcurrency() throws {
        let dag = try makeStoreDag()
        let store = MemoryLeafStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "leaf-store", attributes: .concurrent)

        for leaf in dag.leafs.values {
            group.enter()
            queue.async {
                try? store.storeLeaf(leaf)
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(store.count(), dag.leafs.count)
        XCTAssertEqual(Set(store.getAllLeafHashes()), Set(dag.leafs.keys))
    }

    func testMemoryContentStoreConcurrency() throws {
        let store = MemoryContentStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "content-store", attributes: .concurrent)
        let pairs = (0..<25).map { ("hash-\($0)", ParityTestHelpers.deterministicData(size: $0 + 1)) }

        for (hash, content) in pairs {
            group.enter()
            queue.async {
                try? store.storeContent(hash, content: content)
                group.leave()
            }
        }
        group.wait()

        for (hash, content) in pairs {
            XCTAssertEqual(try store.retrieveContent(hash), content)
        }
    }

    func testBatchOperations() throws {
        let dag = try makeStoreDag()
        let store = MemoryLeafStore()
        let leaves = Array(dag.leafs.values)
        try store.storeLeaves(leaves)
        let retrieved = try store.retrieveLeaves(leaves.map(\.hash))

        XCTAssertEqual(retrieved.count, leaves.count)
        XCTAssertEqual(Set(retrieved.keys), Set(dag.leafs.keys))
    }

    func testEmptyDagStore() throws {
        let store = DagStore.empty()
        XCTAssertEqual(store.root, "")
        XCTAssertFalse(try store.hasLeaf("missing"))
        XCTAssertNil(try store.retrieveLeaf("missing"))
    }

    func testHasLeaf() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)
        let child = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag))
        XCTAssertTrue(try store.hasLeaf(child.hash))
        XCTAssertFalse(try store.hasLeaf("missing"))
    }

    func testDeleteLeaf() throws {
        let dag = try makeStoreDag()
        let leafStore = MemoryLeafStore()
        let store = DagStore.withStorage(dag, leafStore: leafStore)
        let child = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag))

        XCTAssertTrue(try store.hasLeaf(child.hash))
        try store.deleteLeaf(child.hash)
        XCTAssertFalse(try store.hasLeaf(child.hash))
    }

    func testRetrieveLeafWithoutContent() throws {
        let dag = try makeStoreDag()
        let store = DagStore(dag)
        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file))
        let withoutContent = try XCTUnwrap(store.retrieveLeafWithoutContent(fileLeaf.hash))
        XCTAssertNil(withoutContent.content)
        XCTAssertEqual(withoutContent.hash, fileLeaf.hash)
    }

    func testDagStoreVerifyStreaming() throws {
        let dag = try makeStoreDag()
        let receiver = DagStore.empty()
        for packet in dag.getLeafSequence() {
            try receiver.addTransmissionPacket(packet)
        }
        try receiver.verifyStreaming()
    }

    private func makeStoreDag() throws -> Dag {
        let root = try ParityTestHelpers.makeTempDir("store")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        return try createDag(path: root)
    }
}
