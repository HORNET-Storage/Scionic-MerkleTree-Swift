import Foundation
import XCTest
@testable import ScionicMerkleTree

final class StoreStreamingTests: XCTestCase {
    func testDagStoreVerifyStreamingWithCustomStore() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let leafStore = MemoryLeafStore()
            let contentStore = MemoryContentStore()
            let store = DagStore.withStorage(dag, leafStore: leafStore, contentStore: contentStore)

            XCTAssertNoThrow(try store.verifyStreaming(), fixture.name)
        }
    }

    func testDagStoreCreateDirectoryStreaming() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            let outputRoot = try ParityTestHelpers.makeTempDir("dagstore_streaming_output")
            defer { try? FileManager.default.removeItem(atPath: outputRoot) }
            let output = ParityTestHelpers.join(outputRoot, fixture.name)

            try store.createDirectoryStreaming(path: output)
            let recreated = try createDag(path: output)

            XCTAssertEqual(recreated.root, dag.root, fixture.name)
        }
    }

    func testDagStoreIterateDagStreaming() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            var visited: [String] = []

            try store.iterateDagStreaming { leaf, _ in
                visited.append(leaf.hash)
            }

            XCTAssertEqual(Set(visited), Set(dag.leafs.keys), fixture.name)
            XCTAssertEqual(visited.count, dag.leafs.count, fixture.name)
        }
    }

    func testDagStoreCountLeavesStreaming() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            let count = try store.countLeavesStreaming()

            XCTAssertEqual(count, dag.leafs.count, fixture.name)
        }
    }

    func testDagStoreGetContentStreaming() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            guard let fileLeaf = firstFileLeaf(in: dag) else { return }

            let streamingContent = try store.getContentFromLeafStreaming(fileLeaf.hash)
            let regularContent = try store.getContentFromLeaf(fileLeaf.hash)

            XCTAssertEqual(streamingContent, regularContent, fixture.name)
        }
    }

    func testDagStoreVerifyLeafWithParent() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
            guard let childHash = rootLeaf.links.first else { return }

            let proof = rootLeaf.currentLinkCount > 1 ? try rootLeaf.getBranch(key: childHash) : nil
            XCTAssertNoThrow(try store.verifyLeafWithParent(childHash, parentHash: dag.root, proof: proof), fixture.name)
        }
    }

    func testStreamingVerificationMatchesRegular() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            let regularSucceeded = verificationSucceeded { try store.verify() }
            let streamingSucceeded = verificationSucceeded { try store.verifyStreaming() }

            XCTAssertEqual(streamingSucceeded, regularSucceeded, fixture.name)
        }
    }

    func testStreamingWithTransmissionPackets() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let packets = dag.getLeafSequence()
            XCTAssertFalse(packets.isEmpty, fixture.name)

            let receiver = DagStore.empty()
            for packet in packets {
                try receiver.addTransmissionPacket(packet)
            }

            try receiver.verifyStreaming()
            XCTAssertEqual(try receiver.countLeavesStreaming(), dag.leafs.count, fixture.name)
        }
    }

    func testStreamingPartialDagVerification() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
            guard rootLeaf.links.count >= 2 else { return }

            let partial = try dag.getPartial(leafHashes: [rootLeaf.links[0]], pruneLinks: true)
            try partial.verify()
            try DagStore(partial).verifyStreaming()
            XCTAssertTrue(partial.isPartial(), fixture.name)
        }
    }

    func testStreamingPartialDagVerificationMultipleLeaves() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let leafHashes = dag.leafs.keys
                .filter { $0 != dag.root }
                .sorted()
                .prefix(2)
            guard leafHashes.count == 2 else { return }

            let partial = try dag.getPartial(leafHashes: Array(leafHashes), pruneLinks: false)
            try partial.verify()
            try DagStore(partial).verifyStreaming()
        }
    }

    func testStreamingVerificationConsistency() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let fullStore = DagStore(dag)
            XCTAssertEqual(
                verificationSucceeded { try fullStore.verifyStreaming() },
                verificationSucceeded { try fullStore.verify() },
                fixture.name
            )

            let leafHashes = dag.leafs.keys.filter { $0 != dag.root }.sorted()
            guard let leafHash = leafHashes.first else { return }
            let partial = try dag.getPartial(leafHashes: [leafHash], pruneLinks: true)
            let partialStore = DagStore(partial)

            XCTAssertEqual(
                verificationSucceeded { try partialStore.verifyStreaming() },
                verificationSucceeded { try partialStore.verify() },
                fixture.name
            )
        }
    }

    func testStreamingVerificationRigorousComparison() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            try dag.verify()

            let store = DagStore(dag)
            try store.verify()
            try store.verifyStreaming()

            let restored = try store.toDag()
            try restored.verify()
            XCTAssertEqual(restored.root, dag.root, fixture.name)
            XCTAssertEqual(restored.leafs.count, dag.leafs.count, fixture.name)
            XCTAssertEqual(Set(restored.leafs.keys), Set(dag.leafs.keys), fixture.name)
        }
    }

    func testStreamingVerificationDetectsTampering() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            try DagStore(dag).verifyStreaming()
            guard let tamperHash = dag.leafs.keys.first(where: { $0 != dag.root }) else { return }

            let tamperedStore = DagStore.empty()
            for (hash, leaf) in dag.leafs {
                let clone = leaf.clone()
                if hash == tamperHash {
                    clone.itemName = "TAMPERED_" + clone.itemName
                }
                try tamperedStore.storeLeaf(clone)
            }
            tamperedStore.root = dag.root

            XCTAssertThrowsError(try tamperedStore.verifyStreaming(), fixture.name)
        }
    }

    private func firstFileLeaf(in dag: Dag) -> DagLeaf? {
        return dag.leafs.values.first { $0.type == .file }
    }

    private func verificationSucceeded(_ block: () throws -> Void) -> Bool {
        do {
            try block()
            return true
        } catch {
            return false
        }
    }
}
