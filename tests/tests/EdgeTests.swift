import Foundation
import XCTest
@testable import ScionicMerkleTree

final class EdgeTests: XCTestCase {
    func testOutOfRangeLeafRequests() throws {
        let root = try ParityTestHelpers.makeTempDir("edge_range")
        try ParityTestHelpers.createFlatFiles(at: root, count: 3)
        let dag = try createDag(path: root)

        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: 1, end: 1))
        try dag.calculateLabels()
        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: -1, end: 1))
        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: 1, end: dag.labels.count + 10))
        XCTAssertThrowsError(try dag.getPartial(leafHashes: ["missing-hash"], pruneLinks: false))
    }

    func testSingleFileScenarios() throws {
        // The exact.bin/chunked.bin cases assert the LEGACY fixed cutter's
        // size contract (bigger than chunkSize ⇒ child chunk leaves), so pin
        // fixed mode; fastcdc-v1 places content-defined boundaries instead
        // and would usually keep a 2 MiB + 9 file as one chunk.
        setChunkSize(defaultChunkSize)
        defer { setDefaultChunkSize() }

        let cases: [(String, Data)] = [
            ("empty.txt", Data()),
            ("small.txt", "small".data(using: .utf8)!),
            ("exact.bin", ParityTestHelpers.deterministicData(size: defaultChunkSize)),
            ("chunked.bin", ParityTestHelpers.deterministicData(size: defaultChunkSize + 9))
        ]

        for (name, data) in cases {
            let root = try ParityTestHelpers.makeTempDir("edge_single")
            try ParityTestHelpers.writeData(ParityTestHelpers.join(root, name), data)
            let dag = try createDag(path: root)
            let leaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file, named: name))

            XCTAssertEqual(try dag.getContentFromLeaf(leaf), data)
            if data.count > defaultChunkSize {
                XCTAssertFalse(leaf.links.isEmpty)
            }
            try dag.verify()
        }
    }

    func testInvalidPaths() throws {
        let root = try ParityTestHelpers.makeTempDir("edge_invalid")
        let missing = ParityTestHelpers.join(root, "missing")
        XCTAssertThrowsError(try createDag(path: missing))
    }

    func testBrokenDags() throws {
        let root = try ParityTestHelpers.makeTempDir("edge_broken")
        try ParityTestHelpers.createBasicDirectory(at: root)
        let dag = try createDag(path: root)

        let missingChild = ParityTestHelpers.clonedDag(dag)
        let childHash = try XCTUnwrap(missingChild.leafs[missingChild.root]?.links.first)
        missingChild.leafs.removeValue(forKey: childHash)
        XCTAssertThrowsError(try missingChild.verify())

        let changedContent = ParityTestHelpers.clonedDag(dag)
        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: changedContent, type: .file))
        var corruptedContent = fileLeaf.content ?? Data()
        corruptedContent.append(Data("tampered".utf8))
        let corruptedBuilder = DagLeafBuilder(name: fileLeaf.itemName)
        corruptedBuilder.setType(fileLeaf.type)
        corruptedBuilder.setData(corruptedContent)
        let corruptedLeaf = try corruptedBuilder.buildLeaf(additionalData: nil)
        changedContent.leafs[fileLeaf.hash]?.content = corruptedLeaf.content
        changedContent.leafs[fileLeaf.hash]?.contentHash = corruptedLeaf.contentHash
        XCTAssertThrowsError(try changedContent.verify())
    }
}
