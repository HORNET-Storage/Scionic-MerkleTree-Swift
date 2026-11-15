// Several threads build, take in and check what one thread builds, takes in and
// checks. And a build that fails, or whose store falls over, ends: it is told
// as it happened, nobody is left waiting, and no folder is left held open.

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

/// A store that falls over whenever it is handed a chunk, but takes a while to.
private final class SlowToFall: Store, @unchecked Sendable {
    let inner = MemoryStore()

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if kind == .chunk {
            Thread.sleep(forTimeInterval: 0.05)
            throw FellOver()
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

/// A store that will not keep one chunk the first time it is handed it.
private final class RefusingOnce: Store, @unchecked Sendable {
    let inner = MemoryStore()
    private let refused: Hash
    private let asked = Shared(false)

    init(_ refused: Hash) {
        self.refused = refused
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if kind == .chunk && hash == refused && !asked.with({ asked in defer { asked = true }; return asked }) {
            throw ScionicError.invariant("this store will not keep that chunk yet")
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

/// A store that will not keep one file's list.
private final class RefusingList: Store, @unchecked Sendable {
    let inner = MemoryStore()
    private let refused: Hash

    init(_ refused: Hash) {
        self.refused = refused
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if kind == .fileList && hash == refused {
            throw ScionicError.invariant("this store will not keep that list")
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

/// A tree of one file chunked by content, long enough that its chunks are taken
/// in by several threads at once, and the frames of its bundle.
private func longTree(_ seed: String) throws -> (store: MemoryStore, root: Root, frames: [[UInt8]]) {
    let store = MemoryStore()
    let builder = Builder(store: store, chunking: .fastCDCv1)
    let root = try builder.finish(top: builder.file(bytes: corpusBytes(seed, 12 << 20)))
    let bundle = MemorySink()
    try exportBundle(store, root, to: bundle)
    return (store, root, try framesOf(bundle.bytes[Scionic.bundleMagic.count...]))
}

/// A bundle that holds these frames.
private func bundleOf(_ frames: [[UInt8]]) -> [UInt8] {
    var bundle = Scionic.bundleMagic
    for frame in frames {
        bundle += u32be(UInt32(frame.count)) + frame
    }
    return bundle
}

/// Where the chunks' frames are among these frames.
private func chunkPlaces(_ frames: [[UInt8]]) -> [Int] {
    frames.indices.filter { frames[$0].first == FrameTag.chunk }
}

/// A store that holds what `source` holds, with the chunk `hash` damaged: its
/// first byte changed.
private func damagedCopy(_ source: MemoryStore, _ hash: Hash) throws -> MemoryStore {
    let store = MemoryStore()
    for kind in Stored.allCases {
        for held in source.hashes(kind) {
            var bytes = try XCTUnwrap(source.get(kind, held))
            if kind == .chunk && held == hash {
                bytes[0] ^= 1
            }
            try store.put(kind, held, bytes)
        }
    }
    return store
}

/// Bytes that look random, made quickly: a long file for a test.
private func longBytes(_ seed: UInt64, _ length: Int) -> [UInt8] {
    var state = seed | 1
    var out: [UInt8] = []
    out.reserveCapacity(length + 8)
    while out.count < length {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        withUnsafeBytes(of: state.littleEndian) { out.append(contentsOf: $0) }
    }
    out.removeLast(out.count - length)
    return out
}

struct DiskWentAway: Error {}

/// A source that gives at most `step` bytes at a time, and fails once it has
/// given `failsAt`.
private final class Stutter: ByteSource {
    private let data: [UInt8]
    private var at = 0
    private let step: Int
    private let failsAt: Int

    init(_ data: [UInt8], step: Int, failsAt: Int = .max) {
        self.data = data
        self.step = step
        self.failsAt = failsAt
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if at >= failsAt {
            throw DiskWentAway()
        }
        let count = min(buffer.count, step, data.count - at)
        data.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[at..<(at + count)])) }
        at += count
        return count
    }
}

/// The hashes of everything a store holds, by kind.
private func held(_ store: MemoryStore) -> [[Hash]] {
    Stored.allCases.map { store.hashes($0) }
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

    func testABuildThatFailsWithFoldersStillWaitingEndsCleanly() throws {
        // The thread that reads the folder runs ahead of the threads that chunk,
        // by up to 16 folders. Here the store is slow to fall over, so that the
        // walk is that far ahead when the build fails, and the folders that wait
        // are let go of at once. A build that lost count of them there ended
        // the whole program, on Linux and on Apple's systems.
        let temp = try TempDir("threads-slow-falling")
        let folder = temp.join("tree")
        for number in 0..<400 {
            try writeFile(folder + "/dir-\(number % 40)/file-\(padded(number, 3))", corpusBytes("slow-falling-\(number)", 16))
        }
        for workers in [2, 8] {
            var options = smallOptions()
            options.workers = workers
            let what = "a build with \(workers) workers"
            assertFell(endsWithin(what) { [options] in try build(SlowToFall(), path: folder, options: options) }, what)
            XCTAssertNoThrow(try movable(folder), "\(what): the folder is still held after the build fell over")
        }
    }

    func testChunksTakenInBySeveralThreadsAreTakenInAsByOne() throws {
        let (source, root, frames) = try longTree("threads-intake")
        let places = chunkPlaces(frames)
        XCTAssertGreaterThan(places.count, 3, "several chunks")
        let imported = MemoryStore()
        try importBundle(imported, root, from: BytesSource(bundleOf(frames)))
        XCTAssertEqual(try contents(imported), try contents(source))
        let fetched = MemoryStore()
        try fetch(fetched, root, from: TestPeer(source))
        XCTAssertEqual(try contents(fetched), try contents(source))

        // A chunk that comes twice in a row is kept once.
        var twice = frames
        twice.insert(frames[places[1]], at: places[1] + 1)
        let store = MemoryStore()
        try importBundle(store, root, from: BytesSource(bundleOf(twice)))
        XCTAssertEqual(try contents(store), try contents(source))
    }

    func testAChunkRefusedAmongOthersIsWhatIsToldAndNothingFalseIsKept() throws {
        let (source, root, frames) = try longTree("threads-forged")
        let places = chunkPlaces(frames)
        // The third chunk's last byte is changed: no list names what it is now.
        // The last chunk, taken in with it, holds nothing, which is refused too,
        // and for another reason: the first one is what is told.
        var forged = frames
        forged[places[2]][forged[places[2]].count - 1] ^= 1
        forged[places[places.count - 1]] = [FrameTag.chunk]
        let store = MemoryStore()
        assertFails(try importBundle(store, root, from: BytesSource(bundleOf(forged))), "notWanted")
        // What was kept is the tree's, and so are the chunks that came before.
        for kind in Stored.allCases {
            for hash in store.hashes(kind) {
                XCTAssertEqual(try store.get(kind, hash), try source.get(kind, hash), "\(kind) \(hash)")
            }
        }
        for place in places[..<2] {
            XCTAssertTrue(try store.has(.chunk, Hash.of(frames[place].dropFirst())))
        }
        // The tree is made whole from what is held.
        try importBundle(store, root, from: BytesSource(bundleOf(frames)))
        XCTAssertEqual(try contents(store), try contents(source))
    }

    func testABadChunkIsToldBeforeAListThatComesAfterIt() throws {
        // A folder of two files, whose bundle holds the first file's chunks and
        // then the second file's list, which this store will not keep. A chunk
        // before that list is forged, and it is what is told: the chunks that
        // are held are taken in before any frame that comes after them.
        let source = MemoryStore()
        let builder = Builder(store: source, chunking: .fastCDCv1)
        let first = try builder.file(bytes: corpusBytes("threads-order-first", 6 << 20))
        let second = try builder.file(bytes: corpusBytes("threads-order-second", 1 << 20))
        let top = try builder.folder([Entry(name: "first", target: first), Entry(name: "second", target: second)])
        let root = try builder.finish(top: top)
        let bundle = MemorySink()
        try exportBundle(source, root, to: bundle)
        var frames = try framesOf(bundle.bytes[Scionic.bundleMagic.count...])
        let list = try XCTUnwrap(frames.lastIndex { $0.first == FrameTag.fileList })
        let forged = try XCTUnwrap(chunkPlaces(frames).first)
        XCTAssertLessThan(forged, list)
        frames[forged][frames[forged].count - 1] ^= 1
        assertFails(try importBundle(RefusingList(second.hash), root, from: BytesSource(bundleOf(frames))), "notWanted")
    }

    func testAChunkThatAStoreCannotKeepIsWantedStill() throws {
        let (source, root, frames) = try longTree("threads-refused-once")
        let places = chunkPlaces(frames)
        let refused = Hash.of(frames[places[1]].dropFirst())
        func notYet<T>(_ body: @autoclosure () throws -> T, _ what: String) {
            if case let .invariant(detail)? = assertFails(try body(), "invariant", what) {
                XCTAssertEqual(detail, "this store will not keep that chunk yet", what)
            }
        }

        // One frame at a time: the chunk is refused, and taken when it comes
        // again.
        var store = RefusingOnce(refused)
        let intake = try Intake(store: store, root: root)
        for frame in frames[..<places[1]] {
            try intake.accept(frame)
        }
        notYet(try intake.accept(frames[places[1]]), "one at a time")
        XCTAssertTrue(try intake.accept(frames[places[1]]).kept)
        for frame in frames[(places[1] + 1)...] {
            try intake.accept(frame)
        }
        _ = try intake.finish()
        XCTAssertEqual(try contents(store.inner), try contents(source))

        // Many at once, from a bundle and from a peer: the tree is made whole
        // from what is held.
        store = RefusingOnce(refused)
        notYet(try importBundle(store, root, from: BytesSource(bundleOf(frames))), "from a bundle")
        XCTAssertFalse(try store.inner.has(.chunk, refused))
        try importBundle(store, root, from: BytesSource(bundleOf(frames)))
        XCTAssertEqual(try contents(store.inner), try contents(source))
        store = RefusingOnce(refused)
        notYet(try fetch(store, root, from: TestPeer(source)), "from a peer")
        try fetch(store, root, from: TestPeer(source))
        XCTAssertEqual(try contents(store.inner), try contents(source))
    }

    func testAStoreThatFallsOverWhileChunksAreTakenInBringsTheFallToTheCaller() throws {
        let (source, root, frames) = try longTree("threads-falling-intake")
        let bundle = bundleOf(frames)
        assertFell(endsWithin("an import") { try importBundle(FallingOnPut(), root, from: BytesSource(bundle)) }, "an import")
        assertFell(endsWithin("a fetch") { try fetch(FallingOnPut(), root, from: TestPeer(source)) }, "a fetch")
    }

    func testABundleEndsAtTheFirstChunkThatIsDamagedOrMissing() throws {
        let (source, root, frames) = try longTree("threads-export")
        let places = chunkPlaces(frames)
        // A bundle holds a file's chunks in the order of the file's list.
        let items = try fileOf(source, recordOf(source, root).top).items
        XCTAssertEqual(places.map { Hash.of(frames[$0].dropFirst()) }, items.map(\.hash))
        // The chunks are read and checked ahead, several at once, and written in
        // order: what comes out is the bundle up to the bad chunk.
        for bad in [places[0], places[2], places[places.count - 1]] {
            let hash = Hash.of(frames[bad].dropFirst())
            let before = bundleOf(Array(frames[..<bad]))

            let damaged = try damagedCopy(source, hash)
            var out = MemorySink()
            assertFails(try exportBundle(damaged, root, to: out), "corrupt", "damaged chunk at frame \(bad)")
            XCTAssertTrue(out.bytes == before, "damaged chunk at frame \(bad)")

            try damaged.remove(.chunk, hash)
            out = MemorySink()
            assertFails(try exportBundle(damaged, root, to: out), "missing", "missing chunk at frame \(bad)")
            XCTAssertTrue(out.bytes == before, "missing chunk at frame \(bad)")
        }
    }

    func testALongFileThatIsReadIsTheFileHeldInMemory() throws {
        // Longer than a window of a builder that works alone, and than the two
        // windows of one that has help.
        let data = longBytes(7, 72 << 20)
        for chunking in [Chunking.fastCDCv1, try Chunking.fixed(3 << 20)] {
            var first: (target: Target, held: [[Hash]])?
            for threads in [1, 3] {
                let store = MemoryStore()
                let builder = Builder(store: store, chunking: chunking, threads: threads)
                let inMemory = try builder.file(bytes: data)
                // Reads that end anywhere, and a window filled in many reads.
                for step in [(1 << 20) + 17, 5_000_011] {
                    let read = try builder.file(from: Stutter(data, step: step))
                    XCTAssertEqual(read, inMemory, "\(chunking), \(threads) threads, step \(step)")
                }
                if let first {
                    XCTAssertEqual(inMemory, first.target, "\(chunking), \(threads) threads")
                    XCTAssertEqual(held(store), first.held, "\(chunking), \(threads) threads")
                } else {
                    first = (inMemory, held(store))
                }
            }
        }
    }

    func testALongFileThatCannotBeReadOrKeptWholeHasNoList() throws {
        let data = longBytes(11, 48 << 20)
        let refused = try ChunkRef.of(Array(Chunking.fastCDCv1.cut(data)[2])).hash
        for threads in [1, 3] {
            // The reader fails in the second window, while the first is kept.
            let store = MemoryStore()
            let builder = Builder(store: store, chunking: .fastCDCv1, threads: threads)
            assertFails(try builder.file(from: Stutter(data, step: 1 << 20, failsAt: 40 << 20)), "stream", "\(threads) threads")
            XCTAssertEqual(store.count(.fileList), 0)

            // The store will not keep a chunk of the first window.
            let refusing = Refusing(refused)
            let refusingBuilder = Builder(store: refusing, chunking: .fastCDCv1, threads: threads)
            assertFails(try refusingBuilder.file(from: Stutter(data, step: 1 << 20)), "invariant", "\(threads) threads")
            XCTAssertEqual(refusing.inner.count(.fileList), 0)
        }
    }

    func testALongFileIsReadBackWholeAndStopsAtADamagedChunk() throws {
        let data = corpusBytes("threads-read", 12 << 20)
        let source = MemoryStore()
        let builder = Builder(store: source, chunking: .fastCDCv1)
        let root = try builder.finish(top: builder.file(bytes: data))
        let file = try recordOf(source, root).top
        XCTAssertTrue(try readFile(source, file) == data)
        // A stretch over several chunks.
        let (offset, length) = (1_000_003, 7 << 20)
        let stretch = MemorySink()
        try readRange(source, file, offset: UInt64(offset), length: UInt64(length), to: stretch)
        XCTAssertTrue(stretch.bytes[...] == data[offset..<(offset + length)])

        // Read and checked ahead, written in order: the bytes before the
        // damaged chunk come out, and nothing from it on.
        let items = try fileOf(source, file).items
        XCTAssertGreaterThan(items.count, 3, "several chunks")
        let out = MemorySink()
        assertFails(try readFile(damagedCopy(source, items[2].hash), file, to: out), "corrupt")
        let before = Int(items[0].length) + Int(items[1].length)
        XCTAssertTrue(out.bytes[...] == data[..<before])
    }
}
