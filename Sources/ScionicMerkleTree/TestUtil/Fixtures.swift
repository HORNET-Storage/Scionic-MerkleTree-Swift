// Fixtures.swift — Deterministic test fixture generation
//
// Ported from testutil/fixtures.go.
// Each fixture creates a known directory structure with deterministic content.
// All content bytes follow the pattern: byte('A' + (i % 26))

import Foundation

// MARK: - TestFixture

/// A deterministic test data structure for testing DAG operations.
public struct TestFixture {
    public let name: String
    public let description: String
    public let setup: (String) throws -> Void
    public let expectedFiles: Int
    public let expectedDirs: Int
    public let expectedChunks: Int
}

// MARK: - Deterministic Content

/// Generates deterministic content of a given size: A, B, C, ..., Z, A, B, ...
public func deterministicContent(size: Int) -> Data {
    var content = Data(capacity: size)
    for i in 0..<size {
        content.append(UInt8(Character("A").asciiValue! + UInt8(i % 26)))
    }
    return content
}

// MARK: - Fixture Definitions

/// All available test fixtures.
public func getAllFixtures() -> [TestFixture] {
    return [
        singleSmallFile(),
        singleLargeFile(),
        flatDirectory(),
        nestedDirectory(),
        deepHierarchy(),
        mixedSizes(),
    ]
}

/// Single 1KB file — no chunking.
public func singleSmallFile() -> TestFixture {
    return TestFixture(
        name: "single_small_file",
        description: "Single 1KB file - no chunking",
        setup: { baseDir in
            let path = (baseDir as NSString).appendingPathComponent("small.txt")
            try deterministicContent(size: 1024).write(to: URL(fileURLWithPath: path))
        },
        expectedFiles: 1,
        expectedDirs: 0,
        expectedChunks: 0
    )
}

/// Single 10KB file — requires chunking (3 chunks at 4KB chunk size).
public func singleLargeFile() -> TestFixture {
    return TestFixture(
        name: "single_large_file",
        description: "Single 10KB file - requires chunking (default chunk size 4KB)",
        setup: { baseDir in
            let path = (baseDir as NSString).appendingPathComponent("large.txt")
            try deterministicContent(size: 10 * 1024).write(to: URL(fileURLWithPath: path))
        },
        expectedFiles: 1,
        expectedDirs: 0,
        expectedChunks: 3
    )
}

/// One directory with 5 small files (no subdirectories).
public func flatDirectory() -> TestFixture {
    return TestFixture(
        name: "flat_directory",
        description: "One directory with 5 small files (no subdirectories)",
        setup: { baseDir in
            let files: [(String, Int)] = [
                ("file1.txt", 512),
                ("file2.txt", 1024),
                ("file3.txt", 768),
                ("file4.txt", 2048),
                ("file5.txt", 256),
            ]
            for (name, size) in files {
                let path = (baseDir as NSString).appendingPathComponent(name)
                try deterministicContent(size: size).write(to: URL(fileURLWithPath: path))
            }
        },
        expectedFiles: 5,
        expectedDirs: 0,
        expectedChunks: 0
    )
}

/// Two-level hierarchy: root → 2 subdirs → 2 files each.
public func nestedDirectory() -> TestFixture {
    return TestFixture(
        name: "nested_directory",
        description: "Two-level hierarchy: root -> 2 subdirs -> 2 files each",
        setup: { baseDir in
            let fm = FileManager.default
            let structure: [(String, [String])] = [
                ("subdir1", ["file1a.txt", "file1b.txt"]),
                ("subdir2", ["file2a.txt", "file2b.txt"]),
            ]
            for (dir, files) in structure {
                let dirPath = (baseDir as NSString).appendingPathComponent(dir)
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
                for (i, fileName) in files.enumerated() {
                    let filePath = (dirPath as NSString).appendingPathComponent(fileName)
                    try deterministicContent(size: 1024 + i * 512).write(to: URL(fileURLWithPath: filePath))
                }
            }
        },
        expectedFiles: 4,
        expectedDirs: 2,
        expectedChunks: 0
    )
}

/// Five-level deep directory structure with a file at each level.
public func deepHierarchy() -> TestFixture {
    return TestFixture(
        name: "deep_hierarchy",
        description: "Five-level deep directory structure",
        setup: { baseDir in
            let fm = FileManager.default
            let deepPath = ["level1", "level2", "level3", "level4", "level5"]
                .reduce(baseDir) { ($0 as NSString).appendingPathComponent($1) }
            try fm.createDirectory(atPath: deepPath, withIntermediateDirectories: true)

            for i in 1...5 {
                var levelPath = (baseDir as NSString).appendingPathComponent("level1")
                if i >= 2 {
                    for j in 2...i {
                        levelPath = (levelPath as NSString).appendingPathComponent("level\(j)")
                    }
                }
                let filePath = (levelPath as NSString).appendingPathComponent("file_at_level_\(i).txt")
                try deterministicContent(size: i * 256).write(to: URL(fileURLWithPath: filePath))
            }
        },
        expectedFiles: 5,
        expectedDirs: 5,
        expectedChunks: 0
    )
}

/// Directory with both small files and large files requiring chunking.
public func mixedSizes() -> TestFixture {
    return TestFixture(
        name: "mixed_sizes",
        description: "Directory with both small files and large files requiring chunking",
        setup: { baseDir in
            let files: [(String, Int)] = [
                ("tiny.txt", 128),
                ("small.txt", 2048),
                ("medium.txt", 5 * 1024),
                ("large.txt", 15 * 1024),
                ("exact_chunk.txt", 4 * 1024),
            ]
            for (name, size) in files {
                let path = (baseDir as NSString).appendingPathComponent(name)
                try deterministicContent(size: size).write(to: URL(fileURLWithPath: path))
            }
        },
        expectedFiles: 5,
        expectedDirs: 0,
        expectedChunks: 6  // 0 + 0 + 2 + 4 + 0
    )
}

// MARK: - Fixture Helpers

/// Creates a fixture in the specified directory. Returns the fixture path.
public func createFixture(baseDir: String, fixture: TestFixture) throws -> String {
    let fm = FileManager.default
    let fixturePath = (baseDir as NSString).appendingPathComponent(fixture.name)
    try fm.createDirectory(atPath: fixturePath, withIntermediateDirectories: true)
    try fixture.setup(fixturePath)
    return fixturePath
}

/// Creates all fixtures. Returns a map of fixture name → fixture path.
public func createAllFixtures(baseDir: String) throws -> [String: String] {
    var paths: [String: String] = [:]
    for fixture in getAllFixtures() {
        paths[fixture.name] = try createFixture(baseDir: baseDir, fixture: fixture)
    }
    return paths
}

/// Runs a test function against all fixtures.
/// ChunkSize is set to 4096 for consistency.
public func runTestWithAllFixtures(
    testFunc: (Dag, TestFixture, String) throws -> Void
) throws {
    setChunkSize(4096)
    defer { setDefaultChunkSize() }

    let fm = FileManager.default
    let tmpDir = NSTemporaryDirectory() + "fixtures_\(UUID().uuidString)"
    defer { try? fm.removeItem(atPath: tmpDir) }

    for fixture in getAllFixtures() {
        let fixturePath = try createFixture(baseDir: tmpDir, fixture: fixture)
        let dag = try createDag(path: fixturePath, timestampRoot: false)
        try testFunc(dag, fixture, fixturePath)
    }
}

/// Runs a test function against multi-file fixtures only.
public func runTestWithMultiFileFixtures(
    testFunc: (Dag, TestFixture, String) throws -> Void
) throws {
    setChunkSize(4096)
    defer { setDefaultChunkSize() }

    let fm = FileManager.default
    let tmpDir = NSTemporaryDirectory() + "fixtures_\(UUID().uuidString)"
    defer { try? fm.removeItem(atPath: tmpDir) }

    let multiFileFixtures = [flatDirectory(), nestedDirectory(), deepHierarchy(), mixedSizes()]
    for fixture in multiFileFixtures {
        let fixturePath = try createFixture(baseDir: tmpDir, fixture: fixture)
        let dag = try createDag(path: fixturePath, timestampRoot: false)
        try testFunc(dag, fixture, fixturePath)
    }
}