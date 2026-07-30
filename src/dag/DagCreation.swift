// DagCreation.swift — DAG creation from filesystem directories and files
//
// Ported from dag/dag.go (creation portion).
// Walks a directory tree, chunks large files, builds leaves bottom-up,
// then constructs the root leaf with BuildRootLeaf.
//
// Key detail for hash compatibility:
//   - Directory entries are sorted by name (matching Go's os.ReadDir)
//   - Chunk names use path joining: relPath/0, relPath/1, etc.
//   - Single-chunk files store data directly (no child chunk leaves)
//   - Relative paths use the parent of the input path as the base

import Foundation

// MARK: - Public API

/// Creates a DAG from a filesystem path (file or directory).
///
/// Mirrors Go's `CreateDag(path, timestampRoot)`.
public func createDag(path: String, timestampRoot: Bool) throws -> Dag {
    var additionalData: [String: String]? = nil

    if timestampRoot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timeString = formatter.string(from: Date())
        additionalData = ["timestamp": timeString]
    }

    return try createDagInternal(path: path, additionalData: additionalData, processor: nil)
}

/// Creates a DAG with custom additional data on the root leaf.
///
/// Mirrors Go's `CreateDagAdvanced(path, additionalData)`.
public func createDagAdvanced(path: String, additionalData: [String: String]) throws -> Dag {
    return try createDagInternal(path: path, additionalData: additionalData, processor: nil)
}

/// Creates a DAG with a custom leaf processor callback.
///
/// Mirrors Go's `CreateDagCustom(path, rootAdditionalData, processor)`.
public func createDagCustom(path: String, rootAdditionalData: [String: String]?, processor: @escaping LeafProcessor) throws -> Dag {
    return try createDagInternal(path: path, additionalData: rootAdditionalData, processor: processor)
}

/// Creates a DAG with full configuration.
///
/// Mirrors Go's `CreateDagWithConfig(path, config)`.
public func createDagWithConfig(path: String, config: DagBuilderConfig?) throws -> Dag {
    let cfg = config ?? DagBuilderConfig.defaultConfig()

    var additionalData: [String: String]? = cfg.additionalData
    if cfg.timestampRoot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timeString = formatter.string(from: Date())
        additionalData = ["timestamp": timeString]
    }

    if cfg.enableParallel {
        return try createDagParallel(path: path, additionalData: additionalData, processor: cfg.processor, config: cfg)
    }
    return try createDagInternal(path: path, additionalData: additionalData, processor: cfg.processor)
}

// MARK: - Internal DAG Creation

private func createDagInternal(path: String, additionalData: [String: String]?, processor: LeafProcessor?) throws -> Dag {
    let dag = DagBuilder()
    let fm = FileManager.default

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        throw DagCreationError.pathNotFound(path)
    }

    // Parent path = directory containing the input path
    let parentPath = (path as NSString).deletingLastPathComponent

    var leaf: DagLeaf

    if isDir.boolValue {
        leaf = try processDirectory(
            fullPath: path, parentPath: parentPath, dag: dag,
            isRoot: true, additionalData: additionalData, processor: processor
        )
    } else {
        leaf = try processFile(
            fullPath: path, parentPath: parentPath, dag: dag,
            isRoot: true, additionalData: additionalData, processor: processor
        )
    }

    // Rebuild as root leaf (adds LeafCount, ContentSize, DagSize to hash)
    let rootBuilder = DagLeafBuilder(name: leaf.itemName)
    rootBuilder.setType(leaf.type)

    for linkHash in leaf.links {
        rootBuilder.addLink(linkHash)
    }

    if let content = leaf.content {
        rootBuilder.setData(content)
    }

    let rootLeaf = try rootBuilder.buildRootLeaf(dag: dag, additionalData: additionalData)

    // Add the root leaf to the builder
    dag.leafs[rootLeaf.hash] = rootLeaf

    return dag.buildDag(root: rootLeaf.hash)
}

// MARK: - Process Directory

private func processDirectory(
    fullPath: String, parentPath: String, dag: DagBuilder,
    isRoot: Bool, additionalData: [String: String]?, processor: LeafProcessor?
) throws -> DagLeaf {
    let relPath = relativePath(from: parentPath, to: fullPath)

    // Apply processor for non-root
    var localAdditionalData = additionalData
    if let processor = processor, !isRoot {
        let customData = processor(fullPath, relPath, true, isRoot, .directory)
        if let customData = customData {
            if localAdditionalData == nil {
                localAdditionalData = [:]
            }
            for (k, v) in customData {
                localAdditionalData![k] = v
            }
        }
    }

    let builder = DagLeafBuilder(name: relPath)
    builder.setType(.directory)

    // Read directory entries — sorted by name (Go's os.ReadDir guarantees this)
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(atPath: fullPath).sorted()

    for childName in entries {
        let childFullPath = (fullPath as NSString).appendingPathComponent(childName)

        var childIsDir: ObjCBool = false
        guard fm.fileExists(atPath: childFullPath, isDirectory: &childIsDir) else {
            continue
        }

        let childLeaf: DagLeaf
        if childIsDir.boolValue {
            childLeaf = try processDirectory(
                fullPath: childFullPath, parentPath: fullPath, dag: dag,
                isRoot: false, additionalData: nil, processor: processor
            )
        } else {
            childLeaf = try processFile(
                fullPath: childFullPath, parentPath: fullPath, dag: dag,
                isRoot: false, additionalData: nil, processor: processor
            )
        }

        builder.addLink(childLeaf.hash)
        dag.addLeaf(childLeaf, parent: nil)
    }

    return try builder.buildLeaf(additionalData: localAdditionalData)
}

// MARK: - Process File

private func processFile(
    fullPath: String, parentPath: String, dag: DagBuilder,
    isRoot: Bool, additionalData: [String: String]?, processor: LeafProcessor?,
    threadSafeAdds: Bool = false
) throws -> DagLeaf {
    let relPath = relativePath(from: parentPath, to: fullPath)

    // Apply processor for non-root
    var localAdditionalData = additionalData
    if let processor = processor, !isRoot {
        let customData = processor(fullPath, relPath, false, isRoot, .file)
        if let customData = customData {
            if localAdditionalData == nil {
                localAdditionalData = [:]
            }
            for (k, v) in customData {
                localAdditionalData![k] = v
            }
        }
    }

    let builder = DagLeafBuilder(name: relPath)
    builder.setType(.file)

    func addChunkLeaf(_ leaf: DagLeaf) {
        if threadSafeAdds {
            dag.addLeafSafe(leaf, parent: nil)
        } else {
            dag.addLeaf(leaf, parent: nil)
        }
    }

    // Stream file in chunks
    var singleChunk: Data? = nil
    var chunkCount = 0

    try streamFileChunks(fullPath: fullPath, chunkSize: chunkSize) { chunk, index in
        chunkCount += 1

        if chunkCount == 1 {
            // Store first chunk — might be the only one
            singleChunk = chunk
            return
        }

        // Multiple chunks — process as child leaves
        if chunkCount == 2, let firstChunk = singleChunk {
            // Process the first chunk we stored earlier
            let chunkBuilder = DagLeafBuilder(name: "0")
            chunkBuilder.setType(.chunk)
            chunkBuilder.setData(firstChunk)

            let chunkLeaf = try chunkBuilder.buildLeaf(additionalData: nil)
            builder.addLink(chunkLeaf.hash)
            addChunkLeaf(chunkLeaf)
            singleChunk = nil
        }

        // Process current chunk
        let chunkBuilder = DagLeafBuilder(name: String(index))
        chunkBuilder.setType(.chunk)
        chunkBuilder.setData(chunk)

        let chunkLeaf = try chunkBuilder.buildLeaf(additionalData: nil)
        builder.addLink(chunkLeaf.hash)
        addChunkLeaf(chunkLeaf)
    }

    // Single chunk — set data directly on the file leaf
    if chunkCount == 1, let data = singleChunk {
        builder.setData(data)
    }

    return try builder.buildLeaf(additionalData: localAdditionalData)
}

// MARK: - Stream File Chunks

/// Reads a file in chunks using streaming I/O.
/// If chunkSize <= 0, reads the entire file as a single fallback chunk.
private func streamFileChunks(fullPath: String, chunkSize: Int, callback: (Data, Int) throws -> Void) throws {
    let fileURL = URL(fileURLWithPath: fullPath)

    if chunkSize <= 0 {
        try callback(try Data(contentsOf: fileURL), 0)
        return
    }

    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    var index = 0
    while true {
        let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty {
            if index == 0 {
                try callback(Data(), 0)
            }
            return
        }

        try callback(chunk, index)
        index += 1
    }
}

// MARK: - Path Helpers

/// Computes relative path from base to target.
/// Mirrors Go's `filepath.Rel(base, target)`.
private func relativePath(from base: String, to target: String) -> String {
    // Normalize paths
    let baseParts = URL(fileURLWithPath: base).standardized.pathComponents
    let targetParts = URL(fileURLWithPath: target).standardized.pathComponents

    // Find common prefix length
    var commonLength = 0
    for i in 0..<min(baseParts.count, targetParts.count) {
        if baseParts[i] == targetParts[i] {
            commonLength = i + 1
        } else {
            break
        }
    }

    // Build relative path from remaining target parts
    let relativeParts = targetParts[commonLength...]
    if relativeParts.isEmpty {
        return "."
    }
    return relativeParts.joined(separator: "/")
}

// Chunk leaves are named with the bare chunk index ("0", "1", "2", ...), which
// is what Go's processFile, processFileParallel and buildGitFileLeaf all emit.
// This file previously joined relPath with an OS-dependent separator to mirror
// Go's filepath.Join, which made every chunked-file CID depend on the platform
// that created the DAG. A chunk name is a synthetic label, not a filesystem
// path, so no separator belongs in it.

// MARK: - Parallel DAG Creation

private func createDagParallel(path: String, additionalData: [String: String]?, processor: LeafProcessor?, config: DagBuilderConfig) throws -> Dag {
    let dag = DagBuilder()
    let fm = FileManager.default

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        throw DagCreationError.pathNotFound(path)
    }

    let parentPath = (path as NSString).deletingLastPathComponent

    var leaf: DagLeaf
    if isDir.boolValue {
        leaf = try processDirectoryParallel(
            fullPath: path, parentPath: parentPath, dag: dag,
            isRoot: true, additionalData: additionalData, processor: processor, config: config
        )
    } else {
        // Single file has no directory fan-out, but keep leaf insertion on the parallel-safe path.
        leaf = try processFile(
            fullPath: path, parentPath: parentPath, dag: dag,
            isRoot: true, additionalData: additionalData, processor: processor,
            threadSafeAdds: true
        )
    }

    let rootBuilder = DagLeafBuilder(name: leaf.itemName)
    rootBuilder.setType(leaf.type)
    for linkHash in leaf.links {
        rootBuilder.addLink(linkHash)
    }
    if let content = leaf.content {
        rootBuilder.setData(content)
    }

    let rootLeaf = try rootBuilder.buildRootLeaf(dag: dag, additionalData: additionalData)
    dag.leafs[rootLeaf.hash] = rootLeaf

    return dag.buildDag(root: rootLeaf.hash)
}

private struct ParallelEntryResult {
    let leaf: DagLeaf
    let index: Int
}

private final class ParallelDirectoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ParallelEntryResult] = []
    private var firstError: Error?

    func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstError != nil
    }

    func append(_ result: ParallelEntryResult) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if firstError == nil {
            firstError = error
        }
    }

    func resultSnapshot() throws -> [ParallelEntryResult] {
        lock.lock()
        defer { lock.unlock() }
        if let error = firstError {
            throw error
        }
        return results
    }
}

private func processDirectoryParallel(
    fullPath: String, parentPath: String, dag: DagBuilder,
    isRoot: Bool, additionalData: [String: String]?, processor: LeafProcessor?,
    config: DagBuilderConfig
) throws -> DagLeaf {
    let relPath = relativePath(from: parentPath, to: fullPath)

    var localAdditionalData = additionalData
    if let processor = processor, !isRoot {
        let customData = processor(fullPath, relPath, true, isRoot, .directory)
        if let customData = customData {
            if localAdditionalData == nil { localAdditionalData = [:] }
            for (k, v) in customData { localAdditionalData![k] = v }
        }
    }

    let builder = DagLeafBuilder(name: relPath)
    builder.setType(.directory)

    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(atPath: fullPath).sorted()

    // Determine worker count
    var maxWorkers = config.maxWorkers
    if maxWorkers == 0 {
        maxWorkers = ProcessInfo.processInfo.processorCount
    } else if maxWorkers < 0 {
        maxWorkers = entries.count
    }
    maxWorkers = min(maxWorkers, entries.count)

    // If 0 or 1 entries, process sequentially
    if entries.count <= 1 {
        for childName in entries {
            let childFullPath = (fullPath as NSString).appendingPathComponent(childName)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: childFullPath, isDirectory: &childIsDir) else { continue }

            let childLeaf: DagLeaf
            if childIsDir.boolValue {
                childLeaf = try processDirectoryParallel(
                    fullPath: childFullPath, parentPath: fullPath, dag: dag,
                    isRoot: false, additionalData: nil, processor: processor, config: config
                )
            } else {
                childLeaf = try processFile(
                    fullPath: childFullPath, parentPath: fullPath, dag: dag,
                    isRoot: false, additionalData: nil, processor: processor,
                    threadSafeAdds: true
                )
            }
            builder.addLink(childLeaf.hash)
            dag.addLeafSafe(childLeaf, parent: nil)
        }
        return try builder.buildLeaf(additionalData: localAdditionalData)
    }

    // Process entries in parallel using DispatchQueue
    let group = DispatchGroup()
    let state = ParallelDirectoryState()
    let semaphore = DispatchSemaphore(value: maxWorkers)

    for (i, childName) in entries.enumerated() {
        let childFullPath = (fullPath as NSString).appendingPathComponent(childName)

        var childIsDir: ObjCBool = false
        guard fm.fileExists(atPath: childFullPath, isDirectory: &childIsDir) else { continue }

        let isChildDir = childIsDir.boolValue
        let index = i

        group.enter()
        semaphore.wait()

        DispatchQueue.global().async {
            defer {
                semaphore.signal()
                group.leave()
            }

            if state.shouldStop() { return }

            do {
                let childLeaf: DagLeaf
                if isChildDir {
                    childLeaf = try processDirectoryParallel(
                        fullPath: childFullPath, parentPath: fullPath, dag: dag,
                        isRoot: false, additionalData: nil, processor: processor, config: config
                    )
                } else {
                    childLeaf = try processFile(
                        fullPath: childFullPath, parentPath: fullPath, dag: dag,
                        isRoot: false, additionalData: nil, processor: processor,
                        threadSafeAdds: true
                    )
                }

                dag.addLeafSafe(childLeaf, parent: nil)
                state.append(ParallelEntryResult(leaf: childLeaf, index: index))
            } catch {
                state.record(error)
            }
        }
    }

    group.wait()

    var results = try state.resultSnapshot()
    results.sort { $0.index < $1.index }

    for result in results {
        builder.addLink(result.leaf.hash)
    }

    return try builder.buildLeaf(additionalData: localAdditionalData)
}

// MARK: - Errors

public enum DagCreationError: Error, Equatable {
    case pathNotFound(String)
    case fileReadError(String)
}
