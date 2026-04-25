import Foundation
import XCTest
@testable import ScionicMerkleTree

final class SerializeTests: XCTestCase {
    func testSerialization() throws {
        try runTestWithAllFixtures { originalDag, fixture, _ in
            let cbor = originalDag.toCBOR()
            let cborRoundTrip = try Dag.fromCBOR(cbor)
            XCTAssertEqual(cborRoundTrip.root, originalDag.root, fixture.name)
            XCTAssertEqual(Set(cborRoundTrip.leafs.keys), Set(originalDag.leafs.keys), fixture.name)
            try cborRoundTrip.verify()

            let json = try originalDag.toJSON()
            let jsonRoundTrip = try Dag.fromJSON(json)
            XCTAssertEqual(jsonRoundTrip.root, originalDag.root, fixture.name)
            XCTAssertEqual(Set(jsonRoundTrip.leafs.keys), Set(originalDag.leafs.keys), fixture.name)
            try jsonRoundTrip.verify()

            let proofBackedFileHash = originalDag.leafs.first { _, leaf in
                guard leaf.type == .file else { return false }
                return originalDag.leafs.values.contains { parent in
                    parent.currentLinkCount > 1 && parent.hasLink(leaf.hash)
                }
            }?.key
            if let fileHash = proofBackedFileHash {
                let partial = try originalDag.getPartial(leafHashes: [fileHash], pruneLinks: true)
                if partial.isPartial() {
                    try partial.verify()
                    let partialRoundTrip = try Dag.fromJSON(try partial.toJSON())
                    try partialRoundTrip.verify()
                    XCTAssertTrue(partialRoundTrip.isPartial(), fixture.name)

                    let proofBearingLeaves = partial.leafs.values.filter { !$0.proofs.isEmpty }
                    XCTAssertFalse(proofBearingLeaves.isEmpty, fixture.name)
                    for leaf in proofBearingLeaves {
                        let restoredLeaf = try XCTUnwrap(partialRoundTrip.leafs[leaf.hash], fixture.name)
                        XCTAssertEqual(Set(restoredLeaf.proofs.keys), Set(leaf.proofs.keys), fixture.name)
                        for (childHash, proof) in leaf.proofs {
                            let restoredProof = try XCTUnwrap(restoredLeaf.proofs[childHash], fixture.name)
                            XCTAssertEqual(restoredProof.leaf, proof.leaf, fixture.name)
                            XCTAssertEqual(restoredProof.proof.siblings, proof.proof.siblings, fixture.name)
                            XCTAssertEqual(restoredProof.proof.path, proof.proof.path, fixture.name)
                        }
                    }
                }
            }

            let packet = try XCTUnwrap(originalDag.getLeafSequence().first, fixture.name)
            let packetJsonRoundTrip = try TransmissionPacket.fromJSON(try packet.toJSON())
            XCTAssertEqual(packetJsonRoundTrip.leaf.hash, packet.leaf.hash, fixture.name)
            XCTAssertEqual(packetJsonRoundTrip.parentHash, packet.parentHash, fixture.name)
            XCTAssertEqual(packetJsonRoundTrip.proofs.count, packet.proofs.count, fixture.name)

            let packetCborRoundTrip = try TransmissionPacket.fromCBOR(packet.toCBOR())
            XCTAssertEqual(packetCborRoundTrip.leaf.hash, packet.leaf.hash, fixture.name)
            XCTAssertEqual(packetCborRoundTrip.parentHash, packet.parentHash, fixture.name)
            XCTAssertEqual(packetCborRoundTrip.proofs.count, packet.proofs.count, fixture.name)
        }
    }
}

