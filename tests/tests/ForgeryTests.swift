import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Each test here is a forgery: it hands a verifier a tree, a packet or a batch
/// that no honest sender could have produced for the root in question, and
/// requires the verifier to refuse it. Every test first checks that the honest
/// form of the same input is accepted, so a refusal cannot come from an
/// unrelated fault in the setup.
final class ForgeryTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scionic-forgery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func flatDag(_ n: Int) throws -> Dag {
        let dir = try tempDir()
        for i in 0..<n {
            let byte = UInt8(ascii: "a") + UInt8(i)
            try Data([byte]).write(to: dir.appendingPathComponent("f\(i).txt"))
        }
        return try createDag(path: dir.path, timestampRoot: false)
    }

    /// A self-consistent leaf that belongs to no DAG. It passes leaf
    /// verification, because a leaf's hash covers only the leaf's own fields.
    private func forgedLeaf(named name: String = "install.sh") throws -> DagLeaf {
        let builder = DagLeafBuilder(name: name)
        builder.setType(.file)
        builder.setData(Data("echo forged".utf8))
        return try builder.buildLeaf(additionalData: nil)
    }

    // MARK: - Forgeries

    /// An extra child appended to a parent of a full DAG has no proof at all.
    func testFullDagRejectsExtraChild() throws {
        let d = try flatDag(3)
        try d.verify()
        let f = try forgedLeaf()
        d.leafs[f.hash] = f
        d.leafs[d.root]!.links.append(f.hash)
        XCTAssertThrowsError(try d.verify(), "full verification accepted an extra child")
    }

    /// A forged child that carries a real sibling's proof under its own hash.
    func testPartialRejectsSiblingProof() throws {
        let d = try flatDag(3)
        let realHash = d.leafs[d.root]!.links[0]
        let partial = try d.getPartial(leafHashes: [realHash], pruneLinks: true)
        try partial.verify()
        let p = partial.leafs[partial.root]!
        let realProof = try XCTUnwrap(p.proofs[realHash], "expected the partial to carry a proof for the real child")
        let f = try forgedLeaf()
        partial.leafs[f.hash] = f
        p.links.append(f.hash)
        p.proofs[f.hash] = realProof
        XCTAssertThrowsError(try partial.verify(), "partial verification accepted a sibling's proof")
    }

    /// A child of a pruned parent, sent leaf by leaf with no proof.
    func testTransmissionRejectsUnprovenChild() throws {
        let d = try flatDag(3)
        let realHash = d.leafs[d.root]!.links[0]
        let partial = try d.getPartial(leafHashes: [realHash], pruneLinks: true)
        let packets = partial.getLeafSequence()
        let recv = Dag(root: partial.root)
        try recv.applyAndVerifyTransmissionPacket(packets[0])
        try recv.verifyTransmissionPacket(packets[1])
        let bad = TransmissionPacket(leaf: try forgedLeaf(), parentHash: partial.root, proofs: [:])
        XCTAssertThrowsError(try recv.verifyTransmissionPacket(bad),
                             "accepted a child of a pruned parent with no proof")
    }

    /// An extra child added to a batch whose parent has all of its children present.
    func testBatchedRejectsExtraChild() throws {
        let d = try flatDag(3)
        var batch = d.getBatchedLeafSequence()[0]
        try Dag(root: d.root).verifyBatchedTransmissionPacket(batch)
        let f = try forgedLeaf()
        batch.leaves.append(f)
        batch.relationships[f.hash] = d.root
        XCTAssertThrowsError(try Dag(root: d.root).verifyBatchedTransmissionPacket(batch),
                             "batched verification accepted an extra child")
    }

    /// A forged leaf under a file that commits to no children, after a CBOR round trip.
    func testDecodedDagRejectsChildUnderFile() throws {
        let d = try flatDag(3)
        let file = d.leafs[d.leafs[d.root]!.links[0]]!
        let f = try forgedLeaf()
        d.leafs[f.hash] = f
        file.links = [f.hash]
        guard let decoded = try? Dag.fromCBOR(d.toCBOR()) else {
            return  // refused while decoding: fine
        }
        XCTAssertThrowsError(try decoded.verify(),
                             "decoded DAG verified with a forged leaf under \(file.itemName)")
    }

    /// No forged leaf, and the leaf count is unchanged: a real leaf that commits
    /// to no children is given a link to another real leaf. Both directions are tried.
    func testFullDagRejectsLinkUnderChildlessLeaf() throws {
        for (fromIndex, toIndex) in [(1, 0), (0, 1)] {
            let d = try flatDag(3)
            let root = d.leafs[d.root]!
            d.leafs[root.links[2]]!.content = nil  // legal, and it turns the size checks off
            try d.verify()
            let from = d.leafs[root.links[fromIndex]]!
            let to = d.leafs[root.links[toIndex]]!
            from.links = [to.hash]  // from commits to zero links
            XCTAssertThrowsError(try d.verify(),
                                 "case \(fromIndex) to \(toIndex): verified a DAG in which \(from.itemName) links to \(to.itemName)")
        }
    }

    /// The same edit in a partial DAG, on eight leaves in turn.
    func testPartialRejectsLinkUnderChildlessLeaf() throws {
        let d = try flatDag(9)
        let kept = Array(d.leafs[d.root]!.links[..<8])
        for (i, h) in kept.enumerated() {
            let partial = try d.getPartial(leafHashes: kept, pruneLinks: true)
            try partial.verify()
            partial.leafs[h]!.links = [kept[(i + 1) % kept.count]]
            XCTAssertThrowsError(try partial.verify(),
                                 "partial verification accepted a link from \(h), which commits to no children")
        }
    }

    /// A forged leaf filed under a real child's key, with its hash field set to the root's hash.
    func testPartialRejectsLeafFiledUnderAnotherHash() throws {
        let d = try flatDag(3)
        let realHash = d.leafs[d.root]!.links[0]
        func build() throws -> Dag {
            let partial = try d.getPartial(leafHashes: [realHash], pruneLinks: true)
            try partial.verify()
            let fake = DagLeaf()
            fake.hash = partial.root  // the field says "root"; the key says realHash
            fake.itemName = partial.leafs[realHash]!.itemName
            fake.type = .file
            fake.content = Data("forged".utf8)
            partial.leafs[realHash] = fake
            return partial
        }
        XCTAssertThrowsError(try build().verify(),
                             "accepted a leaf whose hash differs from the key it is filed under")
        if let decoded = try? Dag.fromCBOR(try build().toCBOR()) {
            XCTAssertThrowsError(try decoded.verify(), "accepted the same DAG after a CBOR round trip")
        }
    }

    /// A later packet that claims to be the root.
    func testTransmissionRejectsForeignRoot() throws {
        let d = try flatDag(3)
        let foreign = try flatDag(2).getLeafSequence()[0]  // the root packet of a different, valid DAG
        let packets = d.getLeafSequence()

        let recv = Dag(root: d.root)
        try recv.applyAndVerifyTransmissionPacket(packets[0])
        XCTAssertThrowsError(try recv.verifyTransmissionPacket(foreign),
                             "accepted a root packet for a root other than the DAG's own")

        let store = DagStore.empty()
        try store.addTransmissionPacket(packets[0])
        try? store.addTransmissionPacket(foreign)
        XCTAssertEqual(store.root, d.root, "a later root packet replaced the store's root")
    }

    /// The store's streaming verifier, given an extra child.
    func testStoreVerifyStreamingRejectsExtraChild() throws {
        let d = try flatDag(3)
        try DagStore(d).verifyStreaming()
        let f = try forgedLeaf()
        d.leafs[f.hash] = f
        d.leafs[d.root]!.links.append(f.hash)
        XCTAssertThrowsError(try DagStore(d).verifyStreaming(),
                             "streaming verification accepted an extra child")
    }

    /// The store's batched intake, given a leaf that is not a child of its parent.
    func testStoreBatchedRejectsUnboundLeaf() throws {
        let d = try flatDag(3)
        var batch = d.getBatchedLeafSequence()[0]
        try DagStore.empty().addBatchedTransmissionPacket(batch)
        let f = try forgedLeaf()
        batch.leaves.append(f)
        batch.relationships[f.hash] = d.root
        let store = DagStore.empty()
        try? store.addBatchedTransmissionPacket(batch)
        XCTAssertFalse((try? store.hasLeaf(f.hash)) ?? false,
                       "the store kept a leaf that is not a child of its parent")
    }

    /// A file must not come back from a shortened list of chunks.
    func testContentRefusesIncompleteFile() throws {
        setChunkSize(16)
        defer { setDefaultChunkSize() }
        let dir = try tempDir()
        var body = Data()  // three 16-byte chunks
        for letter in ["A", "B", "C"] {
            body.append(Data(String(repeating: letter, count: 16).utf8))
        }
        try body.write(to: dir.appendingPathComponent("big.bin"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("other.txt"))
        let d = try createDag(path: dir.path, timestampRoot: false)
        let fileHash = try XCTUnwrap(
            d.leafs.first { $0.value.type == .file && $0.value.links.count == 3 }?.key,
            "expected a file leaf with three chunks")
        let chunks = d.leafs[fileHash]!.links
        let partial = try d.getPartial(leafHashes: chunks, pruneLinks: true)
        try partial.verify()
        let file = partial.leafs[fileHash]!
        XCTAssertEqual(try partial.getContentFromLeaf(file), body, "a complete file must come back whole")

        // Drop the middle chunk the way a sender could: the leaf, its link and its proof.
        partial.leafs.removeValue(forKey: chunks[1])
        file.proofs.removeValue(forKey: chunks[1])
        file.links = [chunks[0], chunks[2]]
        try partial.verify()  // two of three chunks is still a valid partial
        XCTAssertThrowsError(try partial.getContentFromLeaf(file),
                             "returned a shortened file with no error")
    }
}

/// Malformed input must come back as an error: no trap and no hang. A trap takes
/// the whole test process with it, so these are kept apart from the forgeries
/// above, and the one input that can hang a verifier is given a time limit.
final class ForgeryMalformedInputTests: XCTestCase {

    private func flatDag(_ n: Int) throws -> Dag {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scionic-forgery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<n {
            let byte = UInt8(ascii: "a") + UInt8(i)
            try Data([byte]).write(to: dir.appendingPathComponent("f\(i).txt"))
        }
        return try createDag(path: dir.path, timestampRoot: false)
    }

    private func forgedLeaf(named name: String) throws -> DagLeaf {
        let builder = DagLeafBuilder(name: name)
        builder.setType(.file)
        builder.setData(Data("echo forged".utf8))
        return try builder.buildLeaf(additionalData: nil)
    }

    func testNoRootLeafReturnsError() throws {
        let d = try flatDag(5)
        XCTAssertThrowsError(try Dag(root: d.root).verify(), "a DAG with no root leaf was accepted")
    }

    func testNullLeafInJSONReturnsError() throws {
        let json = Data(#"{"Root":"x","Leafs":{"x":null}}"#.utf8)
        XCTAssertThrowsError(try Dag.fromJSON(json).verify(), "a null leaf in JSON was accepted")
    }

    /// A proof cannot be null in memory here, so this one arrives as JSON.
    func testNullProofInJSONReturnsError() throws {
        let d = try flatDag(5)
        let realHash = d.leafs[d.root]!.links[0]
        let partial = try d.getPartial(leafHashes: [realHash], pruneLinks: true)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: partial.toJSON()) as? [String: Any])
        var leafs = try XCTUnwrap(wire["Leafs"] as? [String: Any])
        var root = try XCTUnwrap(leafs[partial.root] as? [String: Any])
        var proofs = try XCTUnwrap(root["stored_proofs"] as? [String: Any])
        proofs[realHash] = NSNull()
        root["stored_proofs"] = proofs
        leafs[partial.root] = root
        wire["Leafs"] = leafs
        let forged = try JSONSerialization.data(withJSONObject: wire)
        XCTAssertThrowsError(try Dag.fromJSON(forged).verify(), "a null proof in JSON was accepted")
    }

    func testLeavesThatListEachOtherReturnError() throws {
        let d = try flatDag(5)
        let realHash = d.leafs[d.root]!.links[0]
        let cycle = try d.getPartial(leafHashes: [realHash], pruneLinks: true)
        let x = try forgedLeaf(named: "x")
        let y = try forgedLeaf(named: "y")
        x.links = [y.hash]
        y.links = [x.hash]
        cycle.leafs[x.hash] = x
        cycle.leafs[y.hash] = y

        // Verification runs on a thread of its own, so that a verifier that never
        // returns fails this test without holding up the rest. The thread is left
        // behind, and ends with the test process.
        let dag = Unchecked(cycle)
        let threw = Unchecked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do {
                try dag.value.verify()
                threw.value = false
            } catch {
                threw.value = true
            }
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        guard done.wait(timeout: .now() + 10) == .success else {
            XCTFail("two forged leaves that list each other: verification did not return")
            return
        }
        XCTAssertEqual(threw.value, true, "two forged leaves that list each other were accepted")
    }
}

/// Carries a value into another thread. The test reads it back only after that
/// thread has signalled that it is done.
private final class Unchecked<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
