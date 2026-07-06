import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Security-fix parity tests mirroring the Go library's audit regression tests:
/// S1 (path traversal), S2 (streaming content-hash verification), and
/// S3 (per-packet Merkle verification of a complete parent).
final class AuditSecurityTests: XCTestCase {

    // MARK: - S1: path traversal in directory reconstruction

    func testCreateDirectoryRejectsPathTraversal() throws {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "s1_\(UUID().uuidString)"
        let input = tmp + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/safe.txt"))
        defer { try? fm.removeItem(atPath: tmp) }

        let dag = try createDag(path: input, timestampRoot: false)

        // Tamper: point the file leaf's itemName outside the target directory.
        for (_, leaf) in dag.leafs where leaf.type == .file {
            leaf.itemName = "../escaped.txt"
        }

        let outputParent = tmp + "/out"
        try fm.createDirectory(atPath: outputParent, withIntermediateDirectories: true)
        let target = outputParent + "/repo"

        XCTAssertThrowsError(try dag.createDirectory(path: target),
                             "traversal itemName should be rejected")
        XCTAssertFalse(fm.fileExists(atPath: outputParent + "/escaped.txt"),
                       "path traversal wrote a file outside the target directory")
    }

    // MARK: - S2: streaming content-hash verification

    func testStreamingDetectsContentTampering() throws {
        setChunkSize(64 * 1024)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "s2_\(UUID().uuidString)"
        let input = tmp + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 200 * 1024)
            .write(to: URL(fileURLWithPath: input + "/big.bin"))
        defer { try? fm.removeItem(atPath: tmp) }

        let dag = try createDag(path: input, timestampRoot: false)

        // Find the chunked file leaf and one of its chunk leaves.
        var fileHash: String? = nil
        var chunkHash: String? = nil
        for (hash, leaf) in dag.leafs where leaf.type == .file && !leaf.links.isEmpty {
            fileHash = hash
            chunkHash = leaf.links.first
        }
        let fh = try XCTUnwrap(fileHash, "no chunked file leaf found")
        let ch = try XCTUnwrap(chunkHash)

        // Tamper one chunk's content while leaving its hash / contentHash intact.
        if let chunk = dag.leafs[ch], let c = chunk.content, !c.isEmpty {
            var t = c
            t[0] ^= 0xFF
            chunk.content = t
        }

        let store = DagStore(dag)
        XCTAssertThrowsError(try store.getContentFromLeafStreaming(fh),
                             "streaming content read should detect chunk content tampering")
    }

    // MARK: - S3: per-packet Merkle verification of a complete parent

    func testBatchedVerifyCatchesForgedChild() throws {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "s3_\(UUID().uuidString)"
        let input = tmp + "/input"
        try fm.createDirectory(atPath: input, withIntermediateDirectories: true)
        for i in 0..<3 {
            try Data([UInt8(0x61 + i)]).write(to: URL(fileURLWithPath: input + "/f\(i).txt"))
        }
        defer { try? fm.removeItem(atPath: tmp) }

        let dag = try createDag(path: input, timestampRoot: false)
        let batches = dag.getBatchedLeafSequence()
        XCTAssertGreaterThan(batches.count, 0)
        let batch = batches[0]

        // Forge one of the root leaf's child links. Link membership is not part
        // of the CID, so structural leaf verification still passes and only the
        // Merkle-root check can catch it.
        var forged = false
        for leaf in batch.leaves {
            if batch.relationships[leaf.hash] == "" && leaf.links.count > 1 {
                leaf.links[0] = "bafkreiforgedchildaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                forged = true
                break
            }
        }
        XCTAssertTrue(forged, "no multi-child root leaf found in the batch")

        let receiver = Dag()
        XCTAssertThrowsError(try receiver.verifyBatchedTransmissionPacket(batch),
                             "batched verify should reject a forged child via the Merkle root")
    }
}
