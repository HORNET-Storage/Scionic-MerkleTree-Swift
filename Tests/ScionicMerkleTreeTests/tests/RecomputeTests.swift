import Foundation
import XCTest
@testable import ScionicMerkleTree

final class RecomputeTests: XCTestCase {
    func testRecomputeLabelsDoesNotBreakVerification() throws {
        let root = try ParityTestHelpers.makeTempDir("recompute_labels")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        let dag = try createDag(path: root)
        let originalRoot = dag.root

        try dag.calculateLabels()
        let firstLabels = dag.labels
        dag.clearLabels()
        try dag.calculateLabels()

        XCTAssertEqual(dag.root, originalRoot)
        XCTAssertEqual(dag.labels, firstLabels)
        try dag.verify()
    }
}
