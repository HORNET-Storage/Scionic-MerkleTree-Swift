import Foundation
import XCTest
@testable import ScionicMerkleTree

final class SizeTests: XCTestCase {
    func testContentSizeAndDagSizeAccuracy() throws {
        let root = try ParityTestHelpers.makeTempDir("size_accuracy")
        let payload = ParityTestHelpers.deterministicData(size: 12_345)
        try ParityTestHelpers.writeData(ParityTestHelpers.join(root, "payload.bin"), payload)

        let dag = try createDag(path: root)
        let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
        XCTAssertEqual(rootLeaf.contentSize, Int64(payload.count))
        XCTAssertGreaterThan(rootLeaf.dagSize, 0)
        try dag.verify()
    }

    func testDirectoryContentSize() throws {
        let root = try ParityTestHelpers.makeTempDir("size_directory")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "a.txt"), "abc")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "nested", "b.txt"), "defgh")
        try ParityTestHelpers.writeData(ParityTestHelpers.join(root, "nested", "c.bin"), ParityTestHelpers.deterministicData(size: 11))

        let dag = try createDag(path: root)
        let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
        XCTAssertEqual(rootLeaf.contentSize, 3 + 5 + 11)
        try dag.verify()
    }

    func testTwoPassSerializationDeterminism() throws {
        try runTestWithMultiFileFixtures { first, fixture, fixturePath in
            let second = try createDag(path: fixturePath)
            let third = try createDag(path: fixturePath)

            try first.verify()
            try second.verify()
            try third.verify()

            let firstRoot = try XCTUnwrap(first.leafs[first.root], fixture.name)
            let secondRoot = try XCTUnwrap(second.leafs[second.root], fixture.name)
            let thirdRoot = try XCTUnwrap(third.leafs[third.root], fixture.name)

            XCTAssertEqual(first.root, second.root, fixture.name)
            XCTAssertEqual(first.root, third.root, fixture.name)
            XCTAssertEqual(firstRoot.dagSize, secondRoot.dagSize, fixture.name)
            XCTAssertEqual(firstRoot.dagSize, thirdRoot.dagSize, fixture.name)
            XCTAssertEqual(firstRoot.contentSize, secondRoot.contentSize, fixture.name)
            XCTAssertEqual(firstRoot.contentSize, thirdRoot.contentSize, fixture.name)
        }
    }

    func testEmptyFileContentSize() throws {
        let root = try ParityTestHelpers.makeTempDir("size_empty_file")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "empty.txt"), "")

        let dag = try createDag(path: root)
        let fileLeaf = try XCTUnwrap(ParityTestHelpers.firstLeaf(in: dag, type: .file, named: "empty.txt"))
        XCTAssertEqual(fileLeaf.contentSize, 0)
        XCTAssertEqual(try dag.getContentFromLeaf(fileLeaf), Data())
        try dag.verify()
    }

    func testSizeFieldsInHash() throws {
        let root = try ParityTestHelpers.makeTempDir("size_hash")
        try ParityTestHelpers.createBasicDirectory(at: root)
        let dag = try createDag(path: root)

        let tamperedContentSize = ParityTestHelpers.clonedDag(dag)
        tamperedContentSize.leafs[tamperedContentSize.root]?.contentSize += 1
        XCTAssertThrowsError(try tamperedContentSize.verify())

        let tamperedDagSize = ParityTestHelpers.clonedDag(dag)
        tamperedDagSize.leafs[tamperedDagSize.root]?.dagSize += 1
        XCTAssertThrowsError(try tamperedDagSize.verify())
    }
}
