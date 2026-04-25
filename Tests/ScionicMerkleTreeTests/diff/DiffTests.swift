import Foundation
import XCTest
@testable import ScionicMerkleTree

final class DiffTests: XCTestCase {
    func testDiffIdenticalDAGs() throws {
        let root = try makeRoot()
        let first = try createDag(path: root)
        let second = try createDag(path: root)
        let diff = dagDiff(first: first, second: second)

        XCTAssertEqual(diff.summary.total, 0)
        XCTAssertTrue(diff.diffs.isEmpty)
    }

    func testDiffDifferentFixtures() throws {
        let base = try ParityTestHelpers.makeTempDir("diff_fixtures")
        defer { try? FileManager.default.removeItem(atPath: base) }

        var dags: [String: Dag] = [:]
        for fixture in getAllFixtures() {
            let path = try createFixture(baseDir: base, fixture: fixture)
            dags[fixture.name] = try createDag(path: path)
        }

        let singleVsFlat = dagDiff(
            first: try XCTUnwrap(dags["single_small_file"]),
            second: try XCTUnwrap(dags["flat_directory"])
        )
        XCTAssertGreaterThan(singleVsFlat.summary.added, 0)

        let flatVsNested = dagDiff(
            first: try XCTUnwrap(dags["flat_directory"]),
            second: try XCTUnwrap(dags["nested_directory"])
        )
        XCTAssertGreaterThan(flatVsNested.summary.total, 0)
    }

    func testDiffAddedLeaves() throws {
        let root = try makeRoot()
        let oldDag = try createDag(path: root)
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "new.txt"), "new")
        let newDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: newDag)

        XCTAssertGreaterThan(diff.summary.added, 0)
        XCTAssertEqual(diff.summary.added, diff.getAddedLeaves().count)
        XCTAssertGreaterThan(diff.summary.removed, 0)
        XCTAssertNotNil(diff.getRemovedLeaves()[oldDag.root])
    }

    func testDiffRemovedLeaves() throws {
        let root = try makeRoot()
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "remove.txt"), "remove")
        let oldDag = try createDag(path: root)
        try FileManager.default.removeItem(atPath: ParityTestHelpers.join(root, "remove.txt"))
        let newDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: newDag)

        XCTAssertGreaterThan(diff.summary.removed, 0)
        XCTAssertEqual(diff.summary.removed, diff.getRemovedLeaves().count)
    }

    func testDiffModifiedLeaves() throws {
        let root = try makeRoot()
        let oldDag = try createDag(path: root)
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "README.md"), "# Modified\n")
        let newDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: newDag)

        XCTAssertGreaterThan(diff.summary.added, 0)
        XCTAssertGreaterThan(diff.summary.removed, 0)
        XCTAssertNotEqual(oldDag.root, newDag.root)
    }

    func testDiffComplexChanges() throws {
        let root = try makeRoot()
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "remove.txt"), "remove")
        let oldDag = try createDag(path: root)

        try FileManager.default.removeItem(atPath: ParityTestHelpers.join(root, "remove.txt"))
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "README.md"), "# Changed\n")
        try ParityTestHelpers.write(ParityTestHelpers.join(root, "added.txt"), "added")
        let newDag = try createDag(path: root)
        let diff = dagDiff(first: oldDag, second: newDag)

        XCTAssertGreaterThan(diff.summary.added, 0)
        XCTAssertGreaterThan(diff.summary.removed, 0)
        XCTAssertEqual(diff.summary.total, diff.summary.added + diff.summary.removed)
    }

    func testDiffIgnoresLabels() throws {
        let root = try makeRoot()
        let first = try createDag(path: root)
        let second = ParityTestHelpers.clonedDag(first)
        try first.calculateLabels()
        second.labels = ["999": second.root]

        let diff = dagDiff(first: first, second: second)
        XCTAssertEqual(diff.summary.total, 0)
    }

    func testDiffNilDAGs() {
        let first = Dag()
        let second = Dag()
        let diff = dagDiff(first: first, second: second)
        XCTAssertEqual(diff.summary.total, 0)
    }

    func testDiffRootChanges() throws {
        try runTestWithMultiFileFixtures { oldDag, fixture, fixturePath in
            let timestampedDag = try ScionicMerkleTree.createDag(path: fixturePath, timestampRoot: true)
            let diff = dagDiff(first: oldDag, second: timestampedDag)

            XCTAssertNotEqual(oldDag.root, timestampedDag.root, fixture.name)
            XCTAssertGreaterThan(diff.summary.total, 0, fixture.name)
            XCTAssertTrue(diff.diffs[oldDag.root] != nil || diff.diffs[timestampedDag.root] != nil, fixture.name)
        }
    }

    private func makeRoot() throws -> String {
        let root = try ParityTestHelpers.makeTempDir("diff")
        try ParityTestHelpers.createBasicDirectory(at: root)
        return root
    }
}
