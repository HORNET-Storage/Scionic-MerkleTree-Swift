import XCTest
@testable import ScionicMerkleTree

/// Tests that run every operation against all 6 standard fixtures.
/// Mirrors Go's RunTestWithAllFixtures pattern.
final class FixtureTests: XCTestCase {

    // MARK: - Basic: Create + Verify all fixtures

    func testAllFixtures_CreateAndVerify() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            try dag.verify()

            // Count files and dirs
            var files = 0, dirs = 0, chunks = 0
            for (_, leaf) in dag.leafs {
                switch leaf.type {
                case .file: files += 1
                case .directory: dirs += 1
                case .chunk: chunks += 1
                }
            }

            XCTAssertEqual(files, fixture.expectedFiles,
                "\(fixture.name): expected \(fixture.expectedFiles) files, got \(files)")
            // dirs includes root
            XCTAssertEqual(dirs, fixture.expectedDirs + 1,
                "\(fixture.name): expected \(fixture.expectedDirs + 1) dirs (incl root), got \(dirs)")
        }
    }

    // MARK: - Serialization round-trip all fixtures

    func testAllFixtures_JsonRoundTrip() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let json = try dag.toJSON()
            let restored = try Dag.fromJSON(json)
            XCTAssertEqual(restored.root, dag.root, "\(fixture.name): root mismatch after JSON round-trip")
            XCTAssertEqual(restored.leafs.count, dag.leafs.count, "\(fixture.name): leaf count mismatch")
            try restored.verify()
        }
    }

    func testAllFixtures_CborRoundTrip() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let cbor = dag.toCBOR()
            let restored = try Dag.fromCBOR(cbor)
            XCTAssertEqual(restored.root, dag.root, "\(fixture.name): root mismatch after CBOR round-trip")
            XCTAssertEqual(restored.leafs.count, dag.leafs.count, "\(fixture.name): leaf count mismatch")
            try restored.verify()
        }
    }

    // MARK: - Directory recreation all fixtures

    func testAllFixtures_CreateDirectory() throws {
        let fm = FileManager.default
        let outputBase = NSTemporaryDirectory() + "fixture_recreate_\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: outputBase) }
        try fm.createDirectory(atPath: outputBase, withIntermediateDirectories: true)

        try runTestWithAllFixtures { dag, fixture, fixturePath in
            let outputDir = (outputBase as NSString).appendingPathComponent(fixture.name)
            try dag.createDirectory(path: outputDir)

            // Verify output directory exists
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: outputDir, isDirectory: &isDir),
                "\(fixture.name): output dir not created")
        }
    }

    // MARK: - Labels all fixtures

    func testAllFixtures_Labels() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            try dag.calculateLabels()
            // Root = "0", all others get numeric labels
            let rootLabel = try dag.getLabel(hash: dag.root)
            XCTAssertEqual(rootLabel, "0", "\(fixture.name): root label should be 0")
            XCTAssertEqual(dag.labels.count, dag.leafs.count - 1,
                "\(fixture.name): labels count should be leafs - 1 (excluding root)")
        }
    }

    // MARK: - Transmission all fixtures

    func testAllFixtures_TransmissionRoundTrip() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let packets = dag.getLeafSequence()
            XCTAssertGreaterThan(packets.count, 0, "\(fixture.name): no packets generated")

            // First packet should be root
            XCTAssertEqual(packets[0].leaf.hash, dag.root, "\(fixture.name): first packet should be root")
            XCTAssertTrue(packets[0].parentHash.isEmpty, "\(fixture.name): root should have empty parentHash")

            let receiver = Dag()
            for packet in packets {
                try receiver.applyAndVerifyTransmissionPacket(packet)
            }

            XCTAssertEqual(receiver.root, dag.root, "\(fixture.name): receiver root mismatch")
            XCTAssertEqual(receiver.leafs.count, dag.leafs.count, "\(fixture.name): receiver leaf count mismatch")
            try receiver.verify()
        }
    }

    // MARK: - DagStore all fixtures

    func testAllFixtures_DagStore() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let store = DagStore(dag)
            XCTAssertEqual(store.root, dag.root, "\(fixture.name): store root mismatch")

            try store.verify()

            let restored = try store.toDag()
            XCTAssertEqual(restored.root, dag.root, "\(fixture.name): restored root mismatch")
            XCTAssertEqual(restored.leafs.count, dag.leafs.count, "\(fixture.name): restored leaf count mismatch")
        }
    }

    // MARK: - Partial DAG (multi-file fixtures only)

    func testMultiFileFixtures_Partial() throws {
        try runTestWithMultiFileFixtures { dag, fixture, _ in
            guard let rootLeaf = dag.leafs[dag.root], !rootLeaf.links.isEmpty else {
                return // Skip fixtures with no children
            }

            let childHash = rootLeaf.links[0]
            let partial = try dag.getPartial(leafHashes: [childHash], pruneLinks: true)

            XCTAssertTrue(partial.isPartial(), "\(fixture.name): partial should be partial")
            XCTAssertEqual(partial.root, dag.root, "\(fixture.name): partial root should match")
            XCTAssertLessThan(partial.leafs.count, dag.leafs.count, "\(fixture.name): partial should have fewer leaves")
            XCTAssertNotNil(partial.leafs[childHash], "\(fixture.name): partial should contain requested leaf")

            let partialRoot = try XCTUnwrap(partial.leafs[partial.root], "\(fixture.name): partial root missing")
            if rootLeaf.currentLinkCount > 1 {
                XCTAssertNotNil(partialRoot.proofs[childHash], "\(fixture.name): partial root missing proof for requested child")
            }
            try partial.verify()
        }
    }

    // MARK: - Content retrieval all fixtures

    func testAllFixtures_ContentRetrieval() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            for (_, leaf) in dag.leafs where leaf.type == .file {
                let content = try dag.getContentFromLeaf(leaf)
                XCTAssertFalse(content.isEmpty, "\(fixture.name): file \(leaf.itemName) has empty content")
            }
        }
    }

    // MARK: - Chunking behavior

    func testChunkingFixtures_ChunkCount() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "chunk_test_\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: tmpDir) }

        for fixture in [singleLargeFile(), mixedSizes()] {
            let fixturePath = try createFixture(baseDir: tmpDir, fixture: fixture)
            let dag = try createDag(path: fixturePath, timestampRoot: false)

            var chunkCount = 0
            for (_, leaf) in dag.leafs where leaf.type == .chunk {
                chunkCount += 1
            }

            XCTAssertEqual(chunkCount, fixture.expectedChunks,
                "\(fixture.name): expected \(fixture.expectedChunks) chunks, got \(chunkCount)")
        }
    }
}