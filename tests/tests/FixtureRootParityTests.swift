import Foundation
import XCTest
@testable import ScionicMerkleTree

final class FixtureRootParityTests: XCTestCase {
    private struct ExpectedFixtureRoot {
        let root: String
        let leaves: Int
        let chunks: Int
        let contentSize: Int64
        let dagSize: Int64
    }

    private let expectedByFixture: [String: ExpectedFixtureRoot] = [
        "single_small_file": ExpectedFixtureRoot(
            root: "bafireiabahlly4rktdhsvhzgd2prjurwuupjo5shdsefkpayhfqefhcvpe",
            leaves: 2,
            chunks: 0,
            contentSize: 1_024,
            dagSize: 1_467
        ),
        "single_large_file": ExpectedFixtureRoot(
            root: "bafireighsz3l24ndzdt4vthraeydfc3ilzajmj56ozbcjav2oablln2zzy",
            leaves: 5,
            chunks: 3,
            contentSize: 10_240,
            dagSize: 11_611
        ),
        "flat_directory": ExpectedFixtureRoot(
            root: "bafireigd6awocke3nmagbspbkv2rfiqqai455eimle27u36ljeytyqdb4u",
            leaves: 6,
            chunks: 0,
            contentSize: 4_608,
            dagSize: 6_005
        ),
        "nested_directory": ExpectedFixtureRoot(
            root: "bafireiekzu7qss4gcgk3ochl3ehk3ee3rmsqjdh7bin4twzdhkgsfw2kme",
            leaves: 7,
            chunks: 0,
            contentSize: 5_120,
            dagSize: 7_015
        ),
        "deep_hierarchy": ExpectedFixtureRoot(
            root: "bafireifzuzba5kihvbxfl5ygrse5pca6aamzumemmrjm32yyl5j4cjdj3u",
            leaves: 11,
            chunks: 0,
            contentSize: 3_840,
            dagSize: 7_120
        ),
        "mixed_sizes": ExpectedFixtureRoot(
            root: "bafireigsytb3lqy7xxuq53376n4xypeyyn3f6a4hnznxso4r52aeobjpsi",
            leaves: 12,
            chunks: 6,
            contentSize: 26_752,
            dagSize: 30_009
        ),
    ]

    func testFixtureRootsMatchGo() throws {
        try runTestWithAllFixtures { dag, fixture, _ in
            let expected = try XCTUnwrap(expectedByFixture[fixture.name], fixture.name)
            let rootLeaf = try XCTUnwrap(dag.leafs[dag.root], fixture.name)
            let chunkCount = dag.leafs.values.filter { $0.type == .chunk }.count

            XCTAssertEqual(dag.root, expected.root, fixture.name)
            XCTAssertEqual(dag.leafs.count, expected.leaves, fixture.name)
            XCTAssertEqual(rootLeaf.leafCount, expected.leaves, fixture.name)
            XCTAssertEqual(chunkCount, expected.chunks, fixture.name)
            XCTAssertEqual(rootLeaf.contentSize, expected.contentSize, fixture.name)
            XCTAssertEqual(rootLeaf.dagSize, expected.dagSize, fixture.name)
            try dag.verify()
        }
    }

    func testChunkingFixtureRootsAreDeterministicAndMatchGo() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let tmpDir = try ParityTestHelpers.makeTempDir("fixture_root_parity")
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        for fixture in [singleLargeFile(), mixedSizes()] {
            let expected = try XCTUnwrap(expectedByFixture[fixture.name], fixture.name)
            var roots: [String] = []

            for iteration in 0..<3 {
                let parent = ParityTestHelpers.join(tmpDir, "\(fixture.name)_\(iteration)")
                try ParityTestHelpers.makeDir(parent)
                let fixturePath = try createFixture(baseDir: parent, fixture: fixture)
                let dag = try ScionicMerkleTree.createDag(path: fixturePath, timestampRoot: false)
                let chunkCount = dag.leafs.values.filter { $0.type == .chunk }.count

                roots.append(dag.root)
                XCTAssertEqual(dag.root, expected.root, fixture.name)
                XCTAssertEqual(dag.leafs.count, expected.leaves, fixture.name)
                XCTAssertEqual(chunkCount, expected.chunks, fixture.name)
                try dag.verify()
            }

            XCTAssertEqual(Set(roots).count, 1, fixture.name)
        }
    }

    func testNestedChunkedFileRootMatchesGoOnWindowsPaths() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let tmpDir = try ParityTestHelpers.makeTempDir("fixture_root_nested_chunk")
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let inputDir = ParityTestHelpers.join(tmpDir, "input")
        let nestedDir = ParityTestHelpers.join(inputDir, "nested", "inner")
        try ParityTestHelpers.makeDir(nestedDir)

        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        try ParityTestHelpers.writeData(ParityTestHelpers.join(nestedDir, "large.bin"), data)

        let dag = try ScionicMerkleTree.createDag(path: inputDir, timestampRoot: false)
        let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
        let chunkCount = dag.leafs.values.filter { $0.type == .chunk }.count

#if os(Windows)
        XCTAssertEqual(dag.root, "bafireifmsypsphu6rwh46fnkhma5kzxwrhdgqog7fardsg5p3bpuiu6kxe")
        XCTAssertTrue(dag.leafs.values.contains { $0.type == .chunk && $0.itemName.contains("\\") })
#else
        XCTAssertTrue(dag.leafs.values.contains { $0.type == .chunk && $0.itemName.contains("/") })
#endif
        XCTAssertEqual(dag.leafs.count, 7)
        XCTAssertEqual(rootLeaf.leafCount, 7)
        XCTAssertEqual(chunkCount, 3)
        XCTAssertEqual(rootLeaf.contentSize, 10_000)
        XCTAssertEqual(rootLeaf.dagSize, 12_026)
        try dag.verify()
    }
}
