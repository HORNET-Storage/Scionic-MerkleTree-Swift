import Foundation
import XCTest
@testable import ScionicMerkleTree

final class TransmissionParityTests: XCTestCase {
    func testLeafByLeafTransmission() throws {
        try runTestWithAllFixtures { originalDag, fixture, _ in
            try originalDag.verify()
            let packets = originalDag.getLeafSequence()
            XCTAssertFalse(packets.isEmpty, fixture.name)
            XCTAssertEqual(packets.first?.leaf.hash, originalDag.root, fixture.name)
            XCTAssertEqual(packets.first?.parentHash, "", fixture.name)

            let receiver = Dag()
            for packet in packets {
                let cborRoundTrip = try TransmissionPacket.fromCBOR(packet.toCBOR())
                let jsonRoundTrip = try TransmissionPacket.fromJSON(try packet.toJSON())
                XCTAssertEqual(jsonRoundTrip.leaf.hash, packet.leaf.hash, fixture.name)
                try receiver.applyAndVerifyTransmissionPacket(cborRoundTrip)
            }

            ParityTestHelpers.assertSameLeafSet(receiver, originalDag)
            try receiver.verify()

            for leaf in receiver.leafs.values {
                leaf.proofs = [:]
            }
            try receiver.verify()
        }
    }

    func testPartialDagTransmission() throws {
        try runTestWithMultiFileFixtures { originalDag, fixture, _ in
            try originalDag.verify()
            let fileHashes = originalDag.leafs
                .filter { $0.value.type == .file }
                .map(\.key)
                .sorted()
                .prefix(3)
            guard !fileHashes.isEmpty else { return }

            let partial = try originalDag.getPartial(leafHashes: Array(fileHashes), pruneLinks: true)
            try partial.verify()
            XCTAssertTrue(partial.isPartial(), fixture.name)

            let packets = partial.getLeafSequence()
            XCTAssertFalse(packets.isEmpty, fixture.name)

            let receiver = Dag()
            for packet in packets {
                let cborRoundTrip = try TransmissionPacket.fromCBOR(packet.toCBOR())
                receiver.applyTransmissionPacket(cborRoundTrip)
                try receiver.verify()
            }

            XCTAssertEqual(receiver.root, partial.root, fixture.name)
            XCTAssertEqual(receiver.leafs.count, partial.leafs.count, fixture.name)
            XCTAssertTrue(receiver.isPartial(), fixture.name)
        }
    }

    func testPartialDagBatchedTransmission() throws {
        setBatchSize(256)
        defer { setDefaultBatchSize() }

        try runTestWithMultiFileFixtures { originalDag, fixture, _ in
            let fileHashes = originalDag.leafs
                .filter { $0.value.type == .file }
                .map(\.key)
                .sorted()
                .prefix(2)
            guard !fileHashes.isEmpty else { return }

            let partial = try originalDag.getPartial(leafHashes: Array(fileHashes), pruneLinks: true)
            try partial.verify()
            XCTAssertTrue(partial.isPartial(), fixture.name)

            let batches = partial.getBatchedLeafSequence()
            XCTAssertGreaterThan(batches.count, 1, fixture.name)
            XCTAssertTrue(
                batches.flatMap(\.leaves).contains { !$0.proofs.isEmpty },
                fixture.name
            )

            let receiver = Dag(root: partial.root)
            for batch in batches {
                try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
            }
            XCTAssertEqual(receiver.root, partial.root, fixture.name)
            XCTAssertEqual(receiver.leafs.count, partial.leafs.count, fixture.name)
            XCTAssertTrue(receiver.isPartial(), fixture.name)
            try receiver.verify()

            let store = DagStore.empty()
            for batch in batches {
                try store.addBatchedTransmissionPacket(batch)
            }
            try store.verifyStreaming()
            let stored = try store.toDag()
            XCTAssertEqual(stored.root, partial.root, fixture.name)
            XCTAssertEqual(stored.leafs.count, partial.leafs.count, fixture.name)
            XCTAssertTrue(stored.isPartial(), fixture.name)
        }
    }

    func testBatchSizeLimits() throws {
        let testDir = try ParityTestHelpers.makeTempDir("transmission_batches")
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let inputDir = ParityTestHelpers.join(testDir, "input")
        try ParityTestHelpers.makeDir(inputDir)

        for dirIndex in 0..<4 {
            let dir = ParityTestHelpers.join(inputDir, ["a", "b", "c", "d"][dirIndex])
            try ParityTestHelpers.makeDir(dir)
            for fileIndex in 0..<3 {
                let data = Data((0..<100_000).map { UInt8(($0 + dirIndex * 3 + fileIndex) % 256) })
                try ParityTestHelpers.writeData(ParityTestHelpers.join(dir, "\(fileIndex + 1).txt"), data)
            }
        }

        let originalDag = try ScionicMerkleTree.createDag(path: inputDir, timestampRoot: true)
        try originalDag.verify()

        let limits = [200 * 1024, 500 * 1024, 2 * 1024 * 1024]
        defer { setDefaultBatchSize() }

        for limit in limits {
            setBatchSize(limit)
            let batches = originalDag.getBatchedLeafSequence()
            XCTAssertFalse(batches.isEmpty, "limit \(limit)")

            for (index, batch) in batches.enumerated() {
                XCTAssertEqual(batch.packetIndex, index, "limit \(limit)")
                XCTAssertEqual(batch.totalPackets, batches.count, "limit \(limit)")
                XCTAssertEqual(batch.relationships.count, batch.leaves.count, "limit \(limit)")
                let cbor = batch.toCBOR()
                XCTAssertLessThanOrEqual(cbor.count, limit * 2, "limit \(limit)")
                let cborRoundTrip = try BatchedTransmissionPacket.fromCBOR(cbor)
                XCTAssertEqual(cborRoundTrip.leaves.map(\.hash), batch.leaves.map(\.hash), "limit \(limit)")
                let jsonRoundTrip = try BatchedTransmissionPacket.fromJSON(try batch.toJSON())
                XCTAssertEqual(jsonRoundTrip.leaves.map(\.hash), batch.leaves.map(\.hash), "limit \(limit)")
            }

            let receiver = Dag(root: originalDag.root)
            for batch in batches {
                try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
            }
            ParityTestHelpers.assertSameLeafSet(receiver, originalDag)
            try receiver.verify()
        }
    }

    func testIncrementalBatching() throws {
        let testDir = try ParityTestHelpers.makeTempDir("transmission_incremental")
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let inputDir = ParityTestHelpers.join(testDir, "input")
        try ParityTestHelpers.makeDir(inputDir)

        for dirIndex in 0..<3 {
            let dir = ParityTestHelpers.join(inputDir, ["a", "b", "c"][dirIndex])
            try ParityTestHelpers.makeDir(dir)
            for fileIndex in 0..<4 {
                let data = Data((0..<2_048).map { UInt8(($0 + dirIndex * 4 + fileIndex) % 256) })
                try ParityTestHelpers.writeData(ParityTestHelpers.join(dir, "\(fileIndex + 1).txt"), data)
            }
        }

        let originalDag = try ScionicMerkleTree.createDag(path: inputDir, timestampRoot: true)
        try originalDag.verify()

        setBatchSize(50 * 1024)
        defer { setDefaultBatchSize() }
        let batches = originalDag.getBatchedLeafSequence()
        XCTAssertFalse(batches.isEmpty)

        var parentFound = false
        var childrenInBatches: [String: Int] = [:]
        for batch in batches where batch.leaves.count > 1 {
            for (childHash, parentHash) in batch.relationships where !parentHash.isEmpty {
                childrenInBatches[parentHash, default: 0] += 1
                let parentInBatch = batch.leaves.contains { $0.hash == parentHash }
                XCTAssertTrue(parentInBatch, "parent \(parentHash) missing for child \(childHash)")
                parentFound = parentFound || parentInBatch
            }
        }

        XCTAssertTrue(parentFound)
        XCTAssertTrue(childrenInBatches.values.contains { $0 > 1 })

        let receiver = Dag(root: originalDag.root)
        for batch in batches {
            try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
        }
        ParityTestHelpers.assertSameLeafSet(receiver, originalDag)
        try receiver.verify()
    }

    func testBatchedTransmissionMerkleProofCorrectness() throws {
        setBatchSize(256)
        defer { setDefaultBatchSize() }

        let root = try ParityTestHelpers.makeTempDir("transmission_batch_proofs")
        try ParityTestHelpers.createFlatFiles(at: root, count: 6)
        let dag = try createDag(path: root)
        let receiver = Dag()

        for batch in dag.getBatchedLeafSequence() {
            try receiver.verifyBatchedTransmissionPacket(batch)
            receiver.applyBatchedTransmissionPacket(batch)
        }
        try receiver.verify()
    }

    func testBatchedTransmissionMerkleProofBugTrigger() throws {
        setBatchSize(200)
        defer { setDefaultBatchSize() }

        let root = try ParityTestHelpers.makeTempDir("transmission_bug_trigger")
        try ParityTestHelpers.createFlatFiles(at: root, count: 12)
        let dag = try createDag(path: root)
        let batches = dag.getBatchedLeafSequence()
        XCTAssertGreaterThan(batches.count, 1)

        let receiver = Dag()
        for batch in batches {
            try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
        }
        XCTAssertEqual(receiver.root, dag.root)
        XCTAssertEqual(receiver.leafs.count, dag.leafs.count)
        try receiver.verify()
    }

    func testDirectMerkleProofValidation() throws {
        let root = try ParityTestHelpers.makeTempDir("transmission_direct_proof")
        try ParityTestHelpers.createFlatFiles(at: root, count: 5)
        let dag = try createDag(path: root)
        let packet = try XCTUnwrap(dag.getLeafSequence().first { !$0.parentHash.isEmpty })
        let parent = try XCTUnwrap(dag.leafs[packet.parentHash])
        let proof = try XCTUnwrap(packet.proofs[packet.leaf.hash])

        try parent.verifyBranch(proof)
    }

    func testPrunedLinksOptimization() throws {
        let root = try ParityTestHelpers.makeTempDir("transmission_pruned")
        try ParityTestHelpers.createFlatFiles(at: root, count: 8)
        let dag = try createDag(path: root)
        let target = try XCTUnwrap(dag.leafs[dag.root]?.links.first)
        let partial = try dag.getPartial(leafHashes: [target], pruneLinks: true)
        let fullRootLinks = try XCTUnwrap(dag.leafs[dag.root]?.links.count)
        let partialRootLinks = try XCTUnwrap(partial.leafs[partial.root]?.links.count)

        XCTAssertLessThan(partialRootLinks, fullRootLinks)
        let receiver = Dag()
        for packet in partial.getLeafSequence() {
            try receiver.applyAndVerifyTransmissionPacket(packet)
        }
        try receiver.verify()
    }
}
