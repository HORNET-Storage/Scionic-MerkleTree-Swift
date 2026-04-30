import Foundation
import XCTest
@testable import ScionicMerkleTree

final class SpecVectorParityTests: XCTestCase {
    private struct VectorManifest: Decodable {
        struct VectorCase: Decodable {
            let name: String
            let rootKind: String
            let rootInputPath: String
            let rootHash: String
            let leafCount: Int
            let fileLeaves: Int
            let directoryLeaves: Int
            let chunkLeaves: Int
            let fullPath: String
            let partials: [String]
            let transmissionPath: String
            let batchedPath: String
            let negativeVectorPaths: [String]

            enum CodingKeys: String, CodingKey {
                case name
                case rootKind = "root_kind"
                case rootInputPath = "root_input_path"
                case rootHash = "root_hash"
                case leafCount = "leaf_count"
                case fileLeaves = "file_leaves"
                case directoryLeaves = "directory_leaves"
                case chunkLeaves = "chunk_leaves"
                case fullPath = "full_path"
                case partials
                case transmissionPath = "transmission_path"
                case batchedPath = "batched_path"
                case negativeVectorPaths = "negative_vector_paths"
            }
        }

        let cases: [VectorCase]
    }

    private struct NegativeMeta: Decodable {
        let expectedErrorContains: String

        enum CodingKeys: String, CodingKey {
            case expectedErrorContains = "expected_error_contains"
        }
    }

    private struct TransmissionSequence: Decodable {
        struct Packet: Decodable {
            let cborBase64: String

            enum CodingKeys: String, CodingKey {
                case cborBase64 = "cbor_base64"
            }
        }

        let packets: [Packet]
    }

    private struct BatchedSequence: Decodable {
        struct Batch: Decodable {
            let cborBase64: String

            enum CodingKeys: String, CodingKey {
                case cborBase64 = "cbor_base64"
            }
        }

        let batches: [Batch]
    }

    private lazy var goRepoRoot: String = {
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).deletingLastPathComponent + "/scionic-merkletree"
    }()

    private lazy var vectorsRoot: String = {
        (goRepoRoot as NSString).appendingPathComponent("spec/vectors")
    }()

    private lazy var manifest: VectorManifest = {
        let manifestPath = (vectorsRoot as NSString).appendingPathComponent("manifest.json")
        let data = try! Data(contentsOf: URL(fileURLWithPath: manifestPath))
        return try! JSONDecoder().decode(VectorManifest.self, from: data)
    }()

    private func vectorPath(_ relativePath: String) -> String {
        (vectorsRoot as NSString).appendingPathComponent(relativePath)
    }

    private func readNegativeMeta(at relativePath: String) throws -> NegativeMeta {
        let metaPath = vectorPath(relativePath + "/meta.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: metaPath))
        return try JSONDecoder().decode(NegativeMeta.self, from: data)
    }

    private func readTransmissionSequence(at relativePath: String) throws -> TransmissionSequence {
        let sequencePath = vectorPath(relativePath + "/sequence.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: sequencePath))
        return try JSONDecoder().decode(TransmissionSequence.self, from: data)
    }

    private func readBatchedSequence(at relativePath: String) throws -> BatchedSequence {
        let sequencePath = vectorPath(relativePath + "/sequence.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: sequencePath))
        return try JSONDecoder().decode(BatchedSequence.self, from: data)
    }

    private func rootInputAbsolutePath(for vectorCase: VectorManifest.VectorCase) -> String {
        let caseRoot = (vectorsRoot as NSString).appendingPathComponent("cases/\(vectorCase.name)")
        return (caseRoot as NSString).appendingPathComponent(vectorCase.rootInputPath)
    }

    func testManifestFullDagVectorsParseAndVerify() throws {
        for vectorCase in manifest.cases {
            let dagPath = vectorPath(vectorCase.fullPath + "/dag.cbor")
            let dag = try Dag.readDag(path: dagPath)

            XCTAssertEqual(dag.root, vectorCase.rootHash, vectorCase.name)
            XCTAssertEqual(dag.leafs.count, vectorCase.leafCount, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .file }.count, vectorCase.fileLeaves, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .directory }.count, vectorCase.directoryLeaves, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .chunk }.count, vectorCase.chunkLeaves, vectorCase.name)

            try dag.verify()
        }
    }

    func testManifestFullDagCBORRoundTrip() throws {
        for vectorCase in manifest.cases {
            let dagPath = vectorPath(vectorCase.fullPath + "/dag.cbor")
            let dag = try Dag.readDag(path: dagPath)
            let roundTripped = try Dag.fromCBOR(dag.toCBOR())

            XCTAssertEqual(roundTripped.root, vectorCase.rootHash, vectorCase.name)
            XCTAssertEqual(roundTripped.leafs.count, vectorCase.leafCount, vectorCase.name)
            try roundTripped.verify()
        }
    }

    func testManifestInputRootsMatchGoVectors() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        for vectorCase in manifest.cases {
            let inputPath = rootInputAbsolutePath(for: vectorCase)
            let dag = try ScionicMerkleTree.createDag(path: inputPath, timestampRoot: false)

            XCTAssertEqual(dag.root, vectorCase.rootHash, vectorCase.name)
            XCTAssertEqual(dag.leafs.count, vectorCase.leafCount, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .file }.count, vectorCase.fileLeaves, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .directory }.count, vectorCase.directoryLeaves, vectorCase.name)
            XCTAssertEqual(dag.leafs.values.filter { $0.type == .chunk }.count, vectorCase.chunkLeaves, vectorCase.name)

            try dag.verify()
        }
    }

    func testManifestNegativeVectorsFailVerification() throws {
        for vectorCase in manifest.cases {
            for negativePath in vectorCase.negativeVectorPaths {
                let meta = try readNegativeMeta(at: negativePath)
                let dagPath = vectorPath(negativePath + "/dag.cbor")
                let dag = try Dag.readDag(path: dagPath)

                XCTAssertThrowsError(try dag.verify(), "\(vectorCase.name): \(negativePath)") { error in
                    let message = String(describing: error)
                    XCTAssertTrue(
                        message.localizedCaseInsensitiveContains(meta.expectedErrorContains),
                        "Expected error containing '\(meta.expectedErrorContains)', got '\(message)'"
                    )
                }
            }
        }
    }

    func testManifestPartialVectorsParseAndVerify() throws {
        for vectorCase in manifest.cases {
            for partialPath in vectorCase.partials {
                let dagPath = vectorPath(partialPath + "/dag.cbor")
                let dag = try Dag.readDag(path: dagPath)

                XCTAssertEqual(dag.root, vectorCase.rootHash, "\(vectorCase.name): \(partialPath)")
                try dag.verify()
            }
        }
    }

    func testManifestTransmissionSequenceCBORParityAndReplay() throws {
        for vectorCase in manifest.cases {
            let sequence = try readTransmissionSequence(at: vectorCase.transmissionPath)
            let receiver = Dag()

            for packetInfo in sequence.packets {
                let cborData = try XCTUnwrap(Data(base64Encoded: packetInfo.cborBase64), vectorCase.name)
                let packet = try TransmissionPacket.fromCBOR(cborData)
                let roundTripped = try TransmissionPacket.fromCBOR(packet.toCBOR())

                XCTAssertEqual(roundTripped.parentHash, packet.parentHash, vectorCase.name)
                XCTAssertEqual(roundTripped.leaf.hash, packet.leaf.hash, vectorCase.name)
                XCTAssertEqual(roundTripped.leaf.links, packet.leaf.links, vectorCase.name)
                XCTAssertEqual(Set(roundTripped.proofs.keys), Set(packet.proofs.keys), vectorCase.name)
                try receiver.applyAndVerifyTransmissionPacket(packet)
            }

            XCTAssertEqual(receiver.root, vectorCase.rootHash, vectorCase.name)
            try receiver.verify()
        }
    }

    func testManifestBatchedSequenceCBORParityAndReplay() throws {
        for vectorCase in manifest.cases {
            let sequence = try readBatchedSequence(at: vectorCase.batchedPath)
            let receiver = Dag()

            for batchInfo in sequence.batches {
                let cborData = try XCTUnwrap(Data(base64Encoded: batchInfo.cborBase64), vectorCase.name)
                let batch = try BatchedTransmissionPacket.fromCBOR(cborData)
                let roundTripped = try BatchedTransmissionPacket.fromCBOR(batch.toCBOR())

                XCTAssertEqual(roundTripped.leaves.map(\.hash), batch.leaves.map(\.hash), vectorCase.name)
                XCTAssertEqual(roundTripped.relationships, batch.relationships, vectorCase.name)
                try receiver.applyAndVerifyBatchedTransmissionPacket(batch)
            }

            XCTAssertEqual(receiver.root, vectorCase.rootHash, vectorCase.name)
            try receiver.verify()
        }
    }
}