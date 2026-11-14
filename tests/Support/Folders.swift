import Foundation
@testable import ScionicMerkleTree

/// A number for each temporary folder of this run.
private let nextTemp = Shared(0)

/// A folder of its own under the system's temporary folder, removed again when
/// it is let go.
final class TempDir {
    let path: String

    init(_ prefix: String) throws {
        let id = nextTemp.with { value -> Int in
            value += 1
            return value
        }
        let name = "scionic-merkletree-swift-\(ProcessInfo.processInfo.processIdentifier)-\(id)-\(prefix)"
        path = NSTemporaryDirectory() + (NSTemporaryDirectory().hasSuffix("/") || NSTemporaryDirectory().hasSuffix("\\") ? "" : "/") + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The path of `name` in this folder: names with `/` between them.
    func join(_ name: String) -> String {
        path + "/" + name
    }
}

/// Writes a file, and the folders on the way to it.
func writeFile(_ path: String, _ bytes: [UInt8]) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

/// Makes a folder, and the folders on the way to it.
func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// The bytes of a file on disk.
func fileBytes(_ path: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
}

/// Chunking into chunks of 16 bytes, so that small files have many chunks.
func smallChunks() -> Chunking {
    try! Chunking.fixed(16)
}

func smallOptions() -> BuildOptions {
    BuildOptions(chunking: smallChunks())
}

/// A folder with files of several sizes, a folder inside a folder, an empty
/// file and an empty folder. Two of its files have the same bytes.
func sampleFolder(_ parent: String, _ name: String) throws -> String {
    let top = parent + "/" + name
    try writeFile(top + "/readme.txt", bytes("a small file"))
    try writeFile(top + "/empty.bin", [])
    try writeFile(top + "/weights/model.bin", corpusBytes("model", 1_000))
    try writeFile(top + "/weights/copy-of-model.bin", corpusBytes("model", 1_000))
    try writeFile(top + "/weights/shards/a.bin", corpusBytes("shard-a", 100))
    try writeFile(top + "/weights/shards/b.bin", corpusBytes("shard-b", 33))
    try writeFile(top + "/data/exactly-two-chunks.bin", corpusBytes("two", 32))
    try makeFolder(top + "/nothing-here")
    return top
}

/// Builds the sample folder into a new store with small chunks.
func sampleTree(_ name: String) throws -> (temp: TempDir, store: MemoryStore, root: Root) {
    let temp = try TempDir(name)
    let folder = try sampleFolder(temp.path, "sample")
    let store = MemoryStore()
    let root = try build(store, path: folder, options: smallOptions())
    return (temp, store, root)
}
