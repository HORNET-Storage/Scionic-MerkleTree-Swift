// Several threads build and check what one thread builds and checks. And a
// build that fails, or whose store falls over, ends: it is told as it happened,
// nobody is left waiting, and no folder is left held open.

import XCTest
@testable import ScionicMerkleTree

/// A store that will not keep one chunk.
private final class Refusing: Store, @unchecked Sendable {
    let inner = MemoryStore()
    private let refused: Hash

    init(_ refused: Hash) {
        self.refused = refused
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if kind == .chunk && hash == refused {
            throw ScionicError.invariant("this store will not keep that chunk")
        }
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

final class ThreadsTests: XCTestCase {
    func testOneFileIsTheSameWhateverNumberOfThreadsKeepItsChunks() throws {
        // 6,250 chunks of 16 bytes: more than a builder hands on at a time.
        let data = corpusBytes("threads-one-file", 100_000)
        var roots: [Root] = []
        var stores: [[String]] = []
        for threads in [1, 2, 8, 0] {
            let store = MemoryStore()
            let builder = Builder(store: store, chunking: smallChunks(), threads: threads)
            let streamed = try builder.file(from: BytesSource(data, awkward: true))
            let inPlace = try builder.file(bytes: data)
            XCTAssertEqual(streamed, inPlace, "\(threads) threads")
            roots.append(try builder.finish(top: streamed))
            stores.append(try contents(store))
        }
        XCTAssertEqual(Set(roots).count, 1)
        XCTAssertTrue(stores.allSatisfy { $0 == stores[0] })
    }

    func testAFileChunkedByContentIsTheSameWithHelp() throws {
        let data = corpusBytes("threads-by-content", 9 << 20)
        var roots: [Root] = []
        for threads in [1, 4] {
            let store = MemoryStore()
            let builder = Builder(store: store, chunking: .fastCDCv1, threads: threads)
            let streamed = try builder.file(from: BytesSource(data))
            XCTAssertEqual(streamed, try builder.file(bytes: data))
            XCTAssertGreaterThan(store.count(.chunk), 2, "several chunks")
            let root = try builder.finish(top: streamed)
            for workers in [1, 4] {
                _ = try verify(store, root, options: VerifyOptions(rechunk: true, workers: workers))
            }
            roots.append(root)
        }
        XCTAssertEqual(roots[0], roots[1])
    }

    func testAFolderIsTheSameWhenThreadsOutnumberItsFiles() throws {
        let temp = try TempDir("threads-folder")
        let folder = try sampleFolder(temp.path, "tree")
        var roots: [Root] = []
        var stores: [[String]] = []
        for workers in [1, 2, 64] {
            let store = MemoryStore()
            var options = smallOptions()
            options.workers = workers
            let root = try build(store, path: folder, options: options)
            _ = try verify(store, root, options: VerifyOptions(workers: workers))
            roots.append(root)
            stores.append(try contents(store))
        }
        XCTAssertEqual(Set(roots).count, 1)
        XCTAssertTrue(stores.allSatisfy { $0 == stores[0] })
    }

    func testAChunkThatCannotBeKeptStopsTheFileWhoeverWasKeepingIt() throws {
        let data = corpusBytes("threads-refused", 100_000)
        let refused = try ChunkRef.of(Array(data[64_000..<64_016])).hash
        for threads in [1, 8] {
            let store = Refusing(refused)
            let builder = Builder(store: store, chunking: smallChunks(), threads: threads)
            assertFails(try builder.file(from: BytesSource(data)), "invariant", "\(threads) threads, from a stream")
            assertFails(try builder.file(bytes: data), "invariant", "\(threads) threads, from memory")
            // A file whose chunks are not all kept has no list.
            XCTAssertEqual(store.inner.count(.fileList), 0)
        }
    }

    func testTheFailureThatIsToldIsTheOneThatHappened() throws {
        // A folder of many files, one of which holds a chunk the store refuses.
        // The threads that stop because of it have nothing of their own to tell.
        let temp = try TempDir("threads-failure")
        let folder = temp.join("tree")
        for number in 0..<64 {
            try writeFile(folder + "/file-\(padded(number, 2))", corpusBytes("failure-\(number)", 64))
        }
        let refused = try ChunkRef.of(Array(corpusBytes("failure-40", 64).prefix(16))).hash
        for workers in [1, 2, 8] {
            var options = smallOptions()
            options.workers = workers
            let error = assertFails(try build(Refusing(refused), path: folder, options: options), "invariant", "\(workers) workers")
            if case let .invariant(detail)? = error {
                XCTAssertEqual(detail, "this store will not keep that chunk")
            }
            XCTAssertNoThrow(try movable(folder), "\(workers) workers: the folder is still held after the build failed")
        }
    }

    func testAStoreThatFallsOverDoesNotLeaveABuildWaiting() throws {
        // More files than the threads take at once: if every thread that chunks
        // is gone, the one that reads the folder must not wait for them.
        let temp = try TempDir("threads-falling")
        let folder = temp.join("tree")
        for number in 0..<400 {
            try writeFile(folder + "/dir-\(number % 40)/file-\(padded(number, 3))", corpusBytes("falling-\(number)", 16))
        }
        for workers in [1, 2, 8] {
            var options = smallOptions()
            options.workers = workers
            let what = "a build with \(workers) workers"
            // The build ends, and it ends as the store did: by falling over.
            assertFell(endsWithin(what) { [options] in try build(FallingOnPut(), path: folder, options: options) }, what)
            // And it has let go of every folder it held.
            XCTAssertNoThrow(try movable(folder), "\(what): the folder is still held after the build fell over")
        }
    }

    func testAStoreThatFallsOverDoesNotLeaveAFileOrACheckWaiting() throws {
        let data = corpusBytes("threads-falling-file", 100_000)
        for threads in [1, 2, 8] {
            let what = "a file with \(threads) threads"
            assertFell(endsWithin(what) { try Builder(store: FallingOnPut(), chunking: smallChunks(), threads: threads).file(from: BytesSource(data)) }, what)
            assertFell(endsWithin(what) { try Builder(store: FallingOnPut(), chunking: smallChunks(), threads: threads).file(bytes: data) }, what)
        }
        // A check of a held tree, whose store falls over when a chunk is asked for.
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let root = try builder.finish(top: builder.file(bytes: data))
        for workers in [1, 2, 8] {
            let what = "a check with \(workers) workers"
            assertFell(endsWithin(what) { try verify(FallingOnGet(store), root, options: VerifyOptions(workers: workers)) }, what)
        }
    }
}
