import Foundation
import XCTest
@testable import ScionicMerkleTree

final class ParallelTests: XCTestCase {
    func testParallelDeterminism() throws {
        let root = try ParityTestHelpers.makeTempDir("parallel_determinism")
        try ParityTestHelpers.createFlatFiles(at: root, count: 24)

        let config = DagBuilderConfig.parallelConfig(workers: 4)
        let dags = try (0..<4).map { _ in try createDagWithConfig(path: root, config: config) }
        let roots = Set(dags.map(\.root))
        XCTAssertEqual(roots.count, 1)
        try dags.forEach { try $0.verify() }
    }

    func testParallelConsistency() throws {
        let root = try ParityTestHelpers.makeTempDir("parallel_consistency")
        try ParityTestHelpers.createFlatFiles(at: root, count: 16)
        try ParityTestHelpers.createDeepHierarchy(at: root)

        let sequential = try createDag(path: root)
        let parallel = try createDagWithConfig(path: root, config: .parallelConfig(workers: 4))

        ParityTestHelpers.assertSameLeafSet(sequential, parallel)
        try sequential.verify()
        try parallel.verify()
    }

    func testParallelWithDifferentWorkerCounts() throws {
        let root = try ParityTestHelpers.makeTempDir("parallel_workers")
        try ParityTestHelpers.createFlatFiles(at: root, count: 18)
        try ParityTestHelpers.writeData(
            ParityTestHelpers.join(root, "large.bin"),
            ParityTestHelpers.deterministicData(size: defaultChunkSize + 17)
        )

        let sequential = try createDag(path: root)
        for workers in [1, 2, 4, 8] {
            let parallel = try createDagWithConfig(path: root, config: .parallelConfig(workers: workers))
            XCTAssertEqual(parallel.root, sequential.root, "worker count \(workers) changed root")
            XCTAssertEqual(parallel.leafs.count, sequential.leafs.count)
            try parallel.verify()
        }
    }
}
