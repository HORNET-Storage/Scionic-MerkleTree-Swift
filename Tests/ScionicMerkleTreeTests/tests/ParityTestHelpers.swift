import Foundation
import XCTest
@testable import ScionicMerkleTree

func createDag(path: String) throws -> Dag {
    try ScionicMerkleTree.createDag(path: path, timestampRoot: false)
}

enum ParityTestHelpers {
    static func makeTempDir(_ prefix: String = "parity") throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func join(_ base: String, _ components: String...) -> String {
        components.reduce(base) { partial, component in
            (partial as NSString).appendingPathComponent(component)
        }
    }

    static func makeDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func write(_ path: String, _ text: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    static func writeData(_ path: String, _ data: Data) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func deterministicData(size: Int, seed: UInt8 = 65) -> Data {
        let bytes = (0..<size).map { offset in UInt8((Int(seed) + offset) % 251) }
        return Data(bytes)
    }

    static func createBasicDirectory(at root: String) throws {
        try makeDir(join(root, "docs"))
        try makeDir(join(root, "src"))
        try write(join(root, "README.md"), "# Basic\n")
        try write(join(root, "docs", "guide.txt"), "guide content\n")
        try write(join(root, "src", "main.swift"), "print(\"hello\")\n")
    }

    static func createDeepHierarchy(at root: String) throws {
        try write(join(root, "root.txt"), "root\n")
        for level in 0..<4 {
            let dir = join(root, "level\(level)")
            try makeDir(dir)
            try write(join(dir, "file\(level).txt"), "level \(level)\n")

            let nested = join(dir, "nested")
            try makeDir(nested)
            for index in 0..<3 {
                try write(join(nested, "nested\(index).txt"), "nested \(level)-\(index)\n")
            }
        }
    }

    static func createFlatFiles(at root: String, count: Int) throws {
        for index in 0..<count {
            try write(join(root, "file\(index).txt"), "file \(index) content\n")
        }
    }

    static func createMixedSizes(at root: String) throws {
        try write(join(root, "empty.txt"), "")
        try write(join(root, "small.txt"), "small")
        try writeData(join(root, "exact.bin"), deterministicData(size: defaultChunkSize))
        try writeData(join(root, "large.bin"), deterministicData(size: defaultChunkSize * 2 + 123))
    }

    static func clonedDag(_ dag: Dag) -> Dag {
        var leafs: [String: DagLeaf] = [:]
        for (hash, leaf) in dag.leafs {
            leafs[hash] = leaf.clone()
        }
        return Dag(root: dag.root, leafs: leafs, labels: dag.labels)
    }

    static func firstLeaf(in dag: Dag, type: LeafType? = nil, named itemName: String? = nil) -> DagLeaf? {
        dag.leafs.values.first { leaf in
            if let type, leaf.type != type { return false }
            if let itemName, leaf.itemName != itemName { return false }
            return leaf.hash != dag.root
        }
    }

    static func leaves(in dag: Dag, type: LeafType? = nil) -> [DagLeaf] {
        dag.leafs.values.filter { leaf in
            leaf.hash != dag.root && (type == nil || leaf.type == type)
        }
    }

    static func leafHashes(in dag: Dag, type: LeafType? = nil) -> [String] {
        leaves(in: dag, type: type).map(\.hash).sorted()
    }

    static func assertSameLeafSet(_ lhs: Dag, _ rhs: Dag, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(lhs.leafs.keys), Set(rhs.leafs.keys), file: file, line: line)
        XCTAssertEqual(lhs.root, rhs.root, file: file, line: line)
    }
}
