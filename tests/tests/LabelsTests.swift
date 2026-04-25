import Foundation
import XCTest
@testable import ScionicMerkleTree

final class LabelsTests: XCTestCase {
    func testCalculateLabelsDeterminism() throws {
        let root = try ParityTestHelpers.makeTempDir("labels_determinism")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        let dag = try createDag(path: root)

        try dag.calculateLabels()
        let first = dag.labels
        try dag.calculateLabels()
        XCTAssertEqual(dag.labels, first)

        let rebuilt = try createDag(path: root)
        try rebuilt.calculateLabels()
        XCTAssertEqual(rebuilt.labels, first)
    }

    func testClearLabels() throws {
        let root = try ParityTestHelpers.makeTempDir("labels_clear")
        try ParityTestHelpers.createBasicDirectory(at: root)
        let dag = try createDag(path: root)

        try dag.calculateLabels()
        XCTAssertFalse(dag.labels.isEmpty)
        dag.clearLabels()
        XCTAssertTrue(dag.labels.isEmpty)
        XCTAssertEqual(try dag.getLabel(hash: dag.root), "0")
        let child = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag))
        XCTAssertThrowsError(try dag.getLabel(hash: child.hash))
    }

    func testLabelTraversalOrder() throws {
        let root = try ParityTestHelpers.makeTempDir("labels_order")
        try ParityTestHelpers.createBasicDirectory(at: root)
        let dag = try createDag(path: root)

        try dag.calculateLabels()
        XCTAssertEqual(dag.labels.count, dag.leafs.count - 1)
        XCTAssertNil(dag.labels["0"])
        for index in 1...dag.labels.count {
            XCTAssertNotNil(dag.labels["\(index)"])
        }
        XCTAssertEqual(Set(dag.labels.values), Set(ParityTestHelpers.leafHashes(in: dag)))
    }

    func testGetHashesByLabelRange() throws {
        let root = try ParityTestHelpers.makeTempDir("labels_range")
        try ParityTestHelpers.createFlatFiles(at: root, count: 8)
        let dag = try createDag(path: root)

        try dag.calculateLabels()
        let firstThree = try dag.getHashesByLabelRange(start: 1, end: 3)
        XCTAssertEqual(firstThree.count, 3)
        let expected = ["1", "2", "3"].compactMap { dag.labels[$0] }
        XCTAssertEqual(firstThree, expected)
        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: 0, end: 1))
        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: 3, end: 2))
        XCTAssertThrowsError(try dag.getHashesByLabelRange(start: 1, end: dag.labels.count + 1))
    }

    func testGetLabel() throws {
        let root = try ParityTestHelpers.makeTempDir("labels_get")
        try ParityTestHelpers.createFlatFiles(at: root, count: 4)
        let dag = try createDag(path: root)

        try dag.calculateLabels()
        XCTAssertEqual(try dag.getLabel(hash: dag.root), "0")
        let leaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag))
        let label = try dag.getLabel(hash: leaf.hash)
        XCTAssertEqual(dag.labels[label], leaf.hash)
        XCTAssertThrowsError(try dag.getLabel(hash: "bafy-missing"))
    }
}
