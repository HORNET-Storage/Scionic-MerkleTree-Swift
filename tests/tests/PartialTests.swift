import Foundation
import XCTest
@testable import ScionicMerkleTree

final class PartialTests: XCTestCase {
    func testGetPartial() throws {
        let root = try ParityTestHelpers.makeTempDir("partial")
        try ParityTestHelpers.createFlatFiles(at: root, count: 6)
        let dag = try createDag(path: root)
        let target = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file))

        let partial = try dag.getPartial(leafHashes: [target.hash], pruneLinks: true)
        XCTAssertEqual(partial.root, dag.root)
        XCTAssertNotNil(partial.leafs[target.hash])
        XCTAssertNotNil(partial.leafs[dag.root])
        XCTAssertTrue(partial.isPartial())
        try partial.verify()
    }

    func testGetPartialWithSingleFile() throws {
        let root = try ParityTestHelpers.makeTempDir("partial_single")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "single.txt"), "single file")
        let dag = try createDag(path: root)
        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file, named: "single.txt"))

        let partial = try dag.getPartial(leafHashes: [fileLeaf.hash], pruneLinks: true)
        XCTAssertEqual(partial.root, dag.root)
        XCTAssertNotNil(partial.leafs[fileLeaf.hash])
        XCTAssertEqual(try partial.getContentFromLeaf(fileLeaf), "single file".data(using: .utf8)!)
        try partial.verify()
    }

    func testGetPartialFromNestedStructure() throws {
        let root = try ParityTestHelpers.makeTempDir("partial_nested")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        let dag = try createDag(path: root)
        let nested = try XCTUnwrap(dag.leafs.values.first { leaf in
            leaf.type == .file && leaf.itemName.hasSuffix("nested2.txt")
        })

        let partial = try dag.getPartial(leafHashes: [nested.hash], pruneLinks: false)
        XCTAssertNotNil(partial.leafs[nested.hash])
        XCTAssertGreaterThan(partial.leafs.count, 2)
        XCTAssertFalse(try partial.getContentFromLeaf(nested).isEmpty)
        try partial.verify()
    }
}
