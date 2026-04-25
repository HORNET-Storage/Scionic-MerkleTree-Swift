import XCTest
@testable import ScionicMerkleTree

/// Deep directory cross-compatibility test.
///
/// Creates a realistic multi-level directory:
///
///     testdir/
///     ├── readme.txt
///     ├── docs/
///     │   ├── guide.txt
///     │   └── api.txt
///     ├── src/
///     │   ├── main.txt
///     │   └── lib/
///     │       ├── utils.txt
///     │       └── helpers.txt
///     └── data/
///         └── config.txt
///
/// 7 files, 4 subdirectories (+root), 3 levels deep.
/// Verifies: root hash matches Go, verify() passes, createDirectory() recreates all files.
final class CrossCompatDeepTests: XCTestCase {

    func testDeepDirectory_FullPipeline() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory() + "deep_crosscompat_\(UUID().uuidString)"
        let root = tmpDir + "/testdir"

        // Create directory structure
        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/src/lib", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/data", withIntermediateDirectories: true)

        // Create files at various levels — EXACT same content as Go test
        try write(root + "/readme.txt", "This is the README file for the project")
        try write(root + "/docs/guide.txt", "Getting started guide content here")
        try write(root + "/docs/api.txt", "API documentation for developers")
        try write(root + "/src/main.txt", "Main source file with entry point")
        try write(root + "/src/lib/utils.txt", "Utility functions and helpers")
        try write(root + "/src/lib/helpers.txt", "Additional helper functions")
        try write(root + "/data/config.txt", "configuration=value\nkey=data")

        defer { try? fm.removeItem(atPath: tmpDir) }

        // ========== CREATE DAG ==========
        let dag = try createDag(path: root, timestampRoot: false)

        // ========== VERIFY ROOT HASH MATCHES GO ==========
        let expectedRoot = "bafireidb74bnd3jalcdjrog3sgnfdkxblqlphtkvbycksk3qpvrzbwzntu"
        XCTAssertEqual(dag.root, expectedRoot,
            "🔴 DEEP DAG ROOT MISMATCH! Swift root does not match Go for multi-level directory!")

        XCTAssertEqual(dag.leafs.count, 12, "Expected 12 leaves (7 files + 4 subdirs + 1 root)")

        // ========== VERIFY ALL INDIVIDUAL LEAF HASHES ==========
        let expectedLeaves: [String: (name: String, type: LeafType, linkCount: Int)] = [
            "bafireiagwomu24byawpabi6ybaml2pyeeim6mfur62lgm42mbmc3a5p224": ("guide.txt", .file, 0),
            "bafireialntcwjpmas6p776q3blz6vvnkyes7twkchtv6mo4zvjpgeo3rqy": ("readme.txt", .file, 0),
            "bafireiaspsfljwfeixrz36s23dfxi467sjq2ur4wbrok637whwyjezlxqu": ("helpers.txt", .file, 0),
            "bafireie6v4qq6im4gbqoy5losadzrmeuiqiwelu3xequ33hv76dg5b4wau": ("utils.txt", .file, 0),
            "bafireieuupf6vtz4raiewiwh7uecfl3vvo47avxg3tsnxa5r3vjhv5a7fa": ("lib", .directory, 2),
            "bafireihl66nsr2gqh5owxxpyl43ofuqimpe5vdotoae6wqzjl23imgncae": ("config.txt", .file, 0),
            "bafireichjrezseonnh4utrjpfg55pc2fpm5pzy3d5pe3ukzho5j244hoga": ("data", .directory, 1),
            "bafireiexdg54x7eetnk2ckbouiu66w6j75iochjbmoegpy5vy7kp72ky6a": ("api.txt", .file, 0),
            "bafireihs3y5ciehbhyr5oua62vdl4kak4zzbzikd5tt2gzgoxbhno7e2hm": ("docs", .directory, 2),
            "bafireiflxvbmm3iiut6e5m7hvk2synwlofnumydozqgugt4iksm2zyamby": ("main.txt", .file, 0),
            "bafireieg5oh5pff7tt2fkau6jfcesdqtubbjzikr2pkc5mozvheoccmqxq": ("src", .directory, 2),
            "bafireidb74bnd3jalcdjrog3sgnfdkxblqlphtkvbycksk3qpvrzbwzntu": ("testdir", .directory, 4),
        ]

        for (hash, expected) in expectedLeaves {
            guard let leaf = dag.leafs[hash] else {
                XCTFail("🔴 Missing leaf: \(expected.name) (\(hash))")
                continue
            }
            XCTAssertEqual(leaf.itemName, expected.name, "Name mismatch for \(hash)")
            XCTAssertEqual(leaf.type, expected.type, "Type mismatch for \(expected.name)")
            XCTAssertEqual(leaf.links.count, expected.linkCount, "Link count mismatch for \(expected.name)")
        }

        // ========== VERIFY DAG INTEGRITY ==========
        try dag.verify()

        // ========== RECREATE DIRECTORY ==========
        let outputDir = tmpDir + "/output"
        try dag.createDirectory(path: outputDir)

        // ========== VERIFY ALL FILE CONTENTS ==========
        try verifyFile(outputDir + "/readme.txt", "This is the README file for the project")
        try verifyFile(outputDir + "/docs/guide.txt", "Getting started guide content here")
        try verifyFile(outputDir + "/docs/api.txt", "API documentation for developers")
        try verifyFile(outputDir + "/src/main.txt", "Main source file with entry point")
        try verifyFile(outputDir + "/src/lib/utils.txt", "Utility functions and helpers")
        try verifyFile(outputDir + "/src/lib/helpers.txt", "Additional helper functions")
        try verifyFile(outputDir + "/data/config.txt", "configuration=value\nkey=data")

        // ========== VERIFY LABELS ==========
        try dag.calculateLabels()
        XCTAssertEqual(dag.labels.count, 11, "Expected 11 labels (12 leaves minus root)")

        let rootLabel = try dag.getLabel(hash: dag.root)
        XCTAssertEqual(rootLabel, "0")

        // Every non-root leaf should have a label
        for (hash, _) in dag.leafs {
            let label = try dag.getLabel(hash: hash)
            XCTAssertFalse(label.isEmpty, "Leaf \(hash) has no label")
        }

        // ========== VERIFY CONTENT ASSEMBLY ==========
        // Test getContentFromLeaf on file leaves
        for (_, leaf) in dag.leafs where leaf.type == .file {
            let content = try dag.getContentFromLeaf(leaf)
            XCTAssertFalse(content.isEmpty, "File \(leaf.itemName) has empty content")
        }
    }

    // MARK: - Helpers

    private func write(_ path: String, _ content: String) throws {
        try content.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    private func verifyFile(_ path: String, _ expected: String) throws {
        let actual = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(actual, expected, "Content mismatch for \(path)")
    }
}