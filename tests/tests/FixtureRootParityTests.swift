import Foundation
import XCTest
@testable import ScionicMerkleTree

// Every fixture root below is platform-independent: Windows, Linux, macOS and
// iOS all produce the same CIDs for the same bytes. Chunked roots used to be
// pinned per platform because Go and this port both named chunk leaves by
// joining relPath with an OS-dependent separator (filepath.Join in dag/dag.go);
// both now emit the bare chunk index, which carries no separator at all. All
// values are authoritative Go output regenerated with tools/gofixtureroots.

final class FixtureRootParityTests: XCTestCase {
    private struct ExpectedFixtureRoot {
        let root: String
        let leaves: Int
        let chunks: Int
        let contentSize: Int64
        let dagSize: Int64
    }

    /// Authoritative Go values from tools/gofixtureroots. Every field, including
    /// the chunked-fixture roots, is identical on every platform.
    private let expectedByFixture: [String: ExpectedFixtureRoot] = [
        "single_small_file": ExpectedFixtureRoot(
            root: "bafireiabahlly4rktdhsvhzgd2prjurwuupjo5shdsefkpayhfqefhcvpe",
            leaves: 2,
            chunks: 0,
            contentSize: 1_024,
            dagSize: 1_467
        ),
        "single_large_file": ExpectedFixtureRoot(
            root: "bafireiel7coatk47jhcsatc4xdjxx3jx7fdqteplhtlxb7y27bzwnstvwy",
            leaves: 5,
            chunks: 3,
            contentSize: 10_240,
            dagSize: 11_581
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
        // medium.txt and large.txt open with byte-identical content, so their
        // first chunk is a single content-addressed leaf shared by both files:
        // 11 leaves and 5 chunks rather than 12 and 6.
        "mixed_sizes": ExpectedFixtureRoot(
            root: "bafireibrvfd6b3unpr27mq72pdsksj26y6hq32ahjmy6i7omfresfleloq",
            leaves: 11,
            chunks: 5,
            contentSize: 22_656,
            dagSize: 25_612
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

    func testNestedChunkedFileRootMatchesGo() throws {
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

        // A chunked file nested inside directories is exactly the case that used
        // to diverge per platform. Chunk names now carry no path and therefore no
        // separator, so this root is identical on every OS.
        XCTAssertEqual(dag.root, "bafireicgewyfpgq5ywxpx7wddgo56ghfeq6a5sszivzwt4h32xufds4s3u")
        for leaf in dag.leafs.values where leaf.type == .chunk {
            XCTAssertFalse(leaf.itemName.contains("/"), leaf.itemName)
            XCTAssertFalse(leaf.itemName.contains("\\"), leaf.itemName)
            XCTAssertNotNil(Int(leaf.itemName), leaf.itemName)
        }

        XCTAssertEqual(dag.leafs.count, 7)
        XCTAssertEqual(rootLeaf.leafCount, 7)
        XCTAssertEqual(chunkCount, 3)
        XCTAssertEqual(rootLeaf.contentSize, 10_000)
        XCTAssertEqual(rootLeaf.dagSize, 11_996)
        try dag.verify()
    }
}
