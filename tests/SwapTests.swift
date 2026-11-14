// A folder is not left by way of a link that takes a file's or a folder's place
// while the folder is read, or while a tree is written into it.
//
// Each test plays the trick at a set moment: a store does it when the library
// puts or asks for a certain thing, which is in the middle of the work.

import Foundation
import XCTest
@testable import ScionicMerkleTree

/// A store that plays a trick in the middle of the library's work: when the
/// first chunk is put, or when the thing it watches for is asked for. The trick
/// is given the bytes being put, and says whether it was played; it is then not
/// played again.
private final class Tricky: Store, @unchecked Sendable {
    let inner = MemoryStore()
    private let watched: (kind: Stored, hash: Hash)?
    private var trick: (([UInt8]) -> Bool)?
    private let lock = Lock()

    init(watching watched: (kind: Stored, hash: Hash)? = nil, _ trick: @escaping ([UInt8]) -> Bool) {
        self.watched = watched
        self.trick = trick
    }

    private func play(_ bytes: [UInt8]) {
        lock.withLock {
            if let trick, trick(bytes) {
                self.trick = nil
            }
        }
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if watched == nil && kind == .chunk {
            play(Array(bytes))
        }
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        if let watched, watched.kind == kind, watched.hash == hash {
            play([])
        }
        return try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

private func holdsChunk(_ store: MemoryStore, _ bytes: [UInt8]) throws -> Bool {
    try store.has(.chunk, ChunkRef.of(bytes).hash)
}

final class SwapTests: XCTestCase {
    func testAFolderThatBecomesALinkWhileItsFolderIsReadIsNotEntered() throws {
        let temp = try TempDir("swap-folder")
        let secret = corpusBytes("swap-secret", 16)
        try writeFile(temp.join("secret/inside"), secret)
        let probe = temp.join("probe")
        guard linkToFolder(probe, temp.join("secret")) else {
            throw XCTSkip("this system would not make such a link")
        }
        removeLink(probe)

        for threads in [1, 4] {
            let top = temp.join("top-\(threads)")
            try writeFile(top + "/a-file", corpusBytes("swap-a", 64))
            try writeFile(top + "/z-dir/inside", corpusBytes("swap-mine", 16))
            let (dir, moved, to) = (top + "/z-dir", top + "/moved", temp.join("secret"))
            // When the first chunk is kept, the folder is given another name, and
            // its own name is given to a link that leads to the secret.
            let store = Tricky { _ in
                if (try? FileManager.default.moveItem(atPath: dir, toPath: moved)) != nil {
                    _ = linkToFolder(dir, to)
                }
                return true
            }
            var options = smallOptions()
            options.workers = threads
            let result = Result { try build(store, path: top, options: options) }
            // Whatever the timing, the secret is not in the tree.
            XCTAssertFalse(try holdsChunk(store.inner, secret), "\(threads) threads")
            // One thread reads the folder's files before it goes down into the
            // folders, so the link is always there when it does.
            if threads == 1 {
                XCTAssertEqual(failure(result)?.caseName, "unsupportedEntry", "\(result)")
            }
        }
    }

    func testAFileThatBecomesALinkWhileItsFolderIsReadIsNotRead() throws {
        let temp = try TempDir("swap-file")
        let secret = corpusBytes("swap-secret-file", 16)
        let secretPath = temp.join("secret-file")
        try writeFile(secretPath, secret)
        let probe = temp.join("probe")
        guard linkToFile(probe, secretPath) else {
            throw XCTSkip("this account cannot make a link to a file")
        }
        removeLink(probe)

        let top = temp.join("top")
        let (x, y) = (corpusBytes("swap-x", 16), corpusBytes("swap-y", 16))
        let (xPath, yPath) = (top + "/x", top + "/y")
        try writeFile(xPath, x)
        try writeFile(yPath, y)
        // Whichever file is chunked first, the other one is swapped for a link to
        // the secret before its turn comes.
        let store = Tricky { chunk in
            let other = chunk == x ? yPath : xPath
            do {
                try FileManager.default.removeItem(atPath: other)
            } catch {
                XCTFail("\(error)")
            }
            XCTAssertTrue(linkToFile(other, secretPath))
            return true
        }
        var options = smallOptions()
        options.workers = 1
        let result = Result { try build(store, path: top, options: options) }
        XCTAssertEqual(failure(result)?.caseName, "unsupportedEntry", "\(result)")
        XCTAssertFalse(try holdsChunk(store.inner, secret))
    }

    func testNothingIsWrittenThroughALinkThatTakesANewFoldersPlace() throws {
        let temp = try TempDir("swap-write")
        let (inner, last) = (corpusBytes("swap-inner", 16), corpusBytes("swap-last", 16))
        let source = temp.join("source")
        try writeFile(source + "/a-file", corpusBytes("swap-first", 16))
        try writeFile(source + "/z-dir/inner", inner)
        try writeFile(source + "/zz-last", last)
        let outside = temp.join("outside")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let probe = temp.join("probe")
        guard linkToFolder(probe, outside) else {
            throw XCTSkip("this system would not make such a link")
        }
        removeLink(probe)

        let plain = MemoryStore()
        let root = try build(plain, path: source, options: smallOptions())
        let folder = try targetAt(plain, root, "z-dir")
        // Two moments. "held": the new folder is open and about to be filled,
        // which is when its list is asked for. "waiting": the new folder is made
        // and waits for its turn, while the file after it is written.
        let moments: [(String, (kind: Stored, hash: Hash))] = [
            ("held", (.folderList, folder.hash)),
            ("waiting", (.chunk, try ChunkRef.of(last).hash)),
        ]
        for (moment, watched) in moments {
            let dest = temp.join("dest-\(moment)")
            let (dir, moved) = (dest + "/z-dir", dest + "/moved")
            let store = Tricky(watching: watched) { _ in
                guard isFolder(dir) else {
                    return false // nothing of the folder is written yet
                }
                // The folder is given another name where the system lets it be,
                // and its own name is given to a link that leads outside.
                if (try? FileManager.default.moveItem(atPath: dir, toPath: moved)) != nil {
                    _ = linkToFolder(dir, outside)
                }
                return true
            }
            XCTAssertEqual(try build(store.inner, path: source, options: smallOptions()), root)
            let result = Result { try writeToDisk(store, root, to: dest) }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: outside).count,
                0,
                "\(moment): something was written outside (\(result))"
            )
            // A folder that is held is filled wherever its name has gone. One that
            // waited and is now a link is not gone into.
            if moment == "held" {
                XCTAssertTrue([dest + "/moved/inner", dest + "/z-dir/inner"].contains(where: isFile), "\(result)")
            } else {
                XCTAssertNotNil(failure(result), "\(result)")
            }
        }
    }
}
