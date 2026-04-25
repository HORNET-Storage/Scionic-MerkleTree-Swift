import Foundation
import XCTest
@testable import ScionicMerkleTree

final class DagTests: XCTestCase {
    func testFull() throws {
        let root = try ParityTestHelpers.makeTempDir("dag_full")
        try ParityTestHelpers.createBasicDirectory(at: root)
        try ParityTestHelpers.writeData(
            ParityTestHelpers.join(root, "large.bin"),
            ParityTestHelpers.deterministicData(size: defaultChunkSize + 33)
        )

        let dag = try createDag(path: root)
        XCTAssertFalse(dag.root.isEmpty)
        XCTAssertEqual(dag.leafs[dag.root]?.type, .directory)
        XCTAssertGreaterThan(dag.leafs.count, 1)
        try dag.verify()

        try dag.calculateLabels()
        XCTAssertEqual(try dag.getLabel(hash: dag.root), "0")
        XCTAssertEqual(dag.labels.count, dag.leafs.count - 1)

        let output = try ParityTestHelpers.makeTempDir("dag_full_output")
        try dag.createDirectory(path: output)
        XCTAssertEqual(try String(contentsOfFile: ParityTestHelpers.join(output, "README.md"), encoding: .utf8), "# Basic\n")
        XCTAssertEqual(try String(contentsOfFile: ParityTestHelpers.join(output, "src", "main.swift"), encoding: .utf8), "print(\"hello\")\n")

        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file, named: "large.bin"))
        XCTAssertEqual(try dag.getContentFromLeaf(fileLeaf).count, defaultChunkSize + 33)
    }
}
