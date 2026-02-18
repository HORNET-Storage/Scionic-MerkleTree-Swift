import XCTest
@testable import ScionicMerkleTree

/// THE ULTIMATE TEST: Create the same directory structure as Go,
/// build a DAG from it, and verify the root hash matches.
///
/// If this passes, the ENTIRE pipeline is compatible:
///   filesystem traversal → file chunking → leaf building →
///   CBOR encoding → SHA-256 → CID → Classic Merkle Trees →
///   root leaf with LeafCount/ContentSize/DagSize
final class CrossCompatDagTests: XCTestCase {

    func testCreateDag_RootMatchesGo() throws {
        setChunkSize(4096)
        defer { setDefaultChunkSize() }

        // Create temp directory with known structure
        let tmpDir = NSTemporaryDirectory() + "crosscompat_\(UUID().uuidString)"
        let input = tmpDir + "/input"
        let subdir = input + "/subdir"
        let fm = FileManager.default

        try fm.createDirectory(atPath: subdir, withIntermediateDirectories: true)

        try "Hello from file one".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/file1.txt"))
        try "Hello from file two".data(using: .utf8)!.write(to: URL(fileURLWithPath: input + "/file2.txt"))
        try "I am nested".data(using: .utf8)!.write(to: URL(fileURLWithPath: subdir + "/nested.txt"))

        defer { try? fm.removeItem(atPath: tmpDir) }

        // Create DAG without timestamp (deterministic)
        let dag = try createDag(path: input, timestampRoot: false)

        // THE MOMENT OF TRUTH
        let expectedRoot = "bafireibf7zhg6orisvqjl6mqskfokize6haalmt2bgthnxrlruauufqg4u"
        XCTAssertEqual(dag.root, expectedRoot,
            "🔴🔴🔴 DAG ROOT MISMATCH! Swift DAG root does not match Go for the same directory! 🔴🔴🔴")

        XCTAssertEqual(dag.leafs.count, 5, "Leaf count mismatch")

        // Verify individual leaf hashes match Go
        let expectedLeaves: [String: (name: String, type: LeafType)] = [
            "bafireiaptl7ndqt7ngu5ctnpghwvwyxekrt66cpzxyzst2nyso7ppq76v4": ("file1.txt", .file),
            "bafireicmmr4urltkiwzp7cx3w2lmpza4zvkpf4gj2llt42f2cyxlwyfd6e": ("file2.txt", .file),
            "bafireidzdh6wxep5jg3gbkrm5gxns7syv6igqmmqngeioidfc2ljadkjzu": ("nested.txt", .file),
            "bafireihanc6pjpcfhhnljfss6227fpjy7ftqi52ubxqomjosv32d2ovehm": ("subdir", .directory),
            "bafireibf7zhg6orisvqjl6mqskfokize6haalmt2bgthnxrlruauufqg4u": ("input", .directory),
        ]

        for (hash, expected) in expectedLeaves {
            guard let leaf = dag.leafs[hash] else {
                XCTFail("Missing leaf: \(hash) (\(expected.name))")
                continue
            }
            XCTAssertEqual(leaf.itemName, expected.name, "Name mismatch for \(hash)")
            XCTAssertEqual(leaf.type, expected.type, "Type mismatch for \(hash)")
        }
    }
}