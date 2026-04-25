import Foundation
import XCTest
@testable import ScionicMerkleTree

final class ParallelNestedTests: XCTestCase {
    func testNestedParallelDeterminism() throws {
        let root = try ParityTestHelpers.makeTempDir("parallel_nested")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        try ParityTestHelpers.writeData(
            ParityTestHelpers.join(root, "level0", "nested", "large.bin"),
            ParityTestHelpers.deterministicData(size: defaultChunkSize * 2 + 5)
        )

        let sequential = try createDag(path: root)
        let firstParallel = try createDagWithConfig(path: root, config: .parallelConfig(workers: 2))
        let secondParallel = try createDagWithConfig(path: root, config: .parallelConfig(workers: 6))

        XCTAssertEqual(firstParallel.root, sequential.root)
        XCTAssertEqual(secondParallel.root, sequential.root)
        XCTAssertEqual(firstParallel.leafs.count, sequential.leafs.count)
        XCTAssertEqual(secondParallel.leafs.count, sequential.leafs.count)
        try firstParallel.verify()
        try secondParallel.verify()
    }
}
