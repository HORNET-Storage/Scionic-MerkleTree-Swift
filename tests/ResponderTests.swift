// A responder keeps the lists it was asked about, so that a busy one does not
// read and hash a long list again for every request.

import XCTest
@testable import ScionicMerkleTree

/// A store that counts how often a list is read from it.
private final class Counting: Store, @unchecked Sendable {
    let inner = MemoryStore()
    private let lock = Lock()
    private var read = 0

    var listsRead: Int {
        lock.withLock { read }
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        if kind == .fileList || kind == .folderList {
            lock.withLock { read += 1 }
        }
        return try inner.get(kind, hash)
    }

    func has(_ kind: Stored, _ hash: Hash) throws -> Bool {
        try inner.has(kind, hash)
    }

    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        try inner.size(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// Asks about two files in turn, as two peers at once would, and says how often
/// a list was read from the store for it.
private func listsReadFor(_ store: Counting, _ responder: Responder, _ files: [Hash]) throws -> Int {
    let before = store.listsRead
    for round: UInt64 in 0..<20 {
        for file in files {
            let requests: [Request] = [
                .chunks(file: file, start: round, count: 2),
                .fileBranch(file: file, start: round, count: 3),
                .fileBytes(file: file, offset: round * 16, length: 20),
            ]
            for request in requests {
                var frames = 0
                try responder.answer(request.encode()) { _ in frames += 1 }
                XCTAssertGreaterThan(frames, 0)
            }
        }
    }
    return store.listsRead - before
}

final class ResponderTests: XCTestCase {
    func testListsThatWereAskedAboutAreNotReadAgain() throws {
        let store = Counting()
        let builder = Builder(store: store, chunking: smallChunks())
        let first = try builder.file(bytes: corpusBytes("responder-a", 1_600))
        let second = try builder.file(bytes: corpusBytes("responder-b", 1_600))
        let files = [first.hash, second.hash]

        // Each of the two lists is read once, for 120 requests.
        XCTAssertEqual(try listsReadFor(store, Responder(store), files), 2)
        // A responder that keeps one list only reads again at every change.
        XCTAssertEqual(try listsReadFor(store, Responder(store, recent: 0), files), 40)

        // A list that was harmed in the store is named, not served.
        try store.inner.remove(.fileList, first.hash)
        try store.inner.put(.fileList, first.hash, [UInt8](repeating: 7, count: 72))
        let request = Request.fileBranch(file: first.hash, start: 0, count: 1)
        if case let .corrupt(_, hash)? = assertFails(try Responder(store).answer(request.encode()) { _ in }, "corrupt") {
            XCTAssertEqual(hash, first.hash)
        }
    }

    func testAResponderCanKeepToItselfWhichChunksItHolds() throws {
        let store = MemoryStore()
        let file = try Builder(store: store, chunking: smallChunks()).file(bytes: corpusBytes("responder-have", 160))
        let request = Request.have(file.hash).encode()
        func answer(_ responder: Responder) throws -> Frame {
            var frames: [[UInt8]] = []
            try responder.answer(request) { frames.append($0) }
            XCTAssertEqual(frames.count, 1)
            return try Frame(decoding: frames[0])
        }
        guard case let .have(map) = try answer(Responder(store)) else {
            return XCTFail("no map")
        }
        XCTAssertEqual(map.count, 10)
        XCTAssertEqual(map.held, 10)
        XCTAssertEqual(try answer(Responder(store, have: false)), .refused(.notHeld))
    }

    func testAListReadWithItsTreeIsTheListReadAlone() throws {
        for count in [0, 1, 2, 3, 5, 8, 13, 100] {
            let items = try (0..<count).map { try ChunkRef.of(corpusBytes("chunk-\($0)", 16)) }
            let list = try FileList(items: items)
            let open = try OpenFile(decoding: list.encode())
            XCTAssertEqual(open.list, list, "\(count) chunks")
            if count > 0 {
                let end = UInt64(min(count, 3))
                XCTAssertEqual(try open.open(start: 0, end: end).encode(), try OpenFile(list).open(start: 0, end: end).encode())
            }
        }
        let file = try FileList(items: [ChunkRef.of(bytes("some bytes"))]).target
        func entry(_ number: Int) throws -> Entry {
            try Entry(name: "name-\(padded(number, 3))", target: file)
        }
        for count in [0, 1, 2, 3, 7, 50] {
            let list = try FolderList(entries: (0..<count).map(entry))
            let open = try OpenFolder(decoding: list.encode())
            XCTAssertEqual(open.list, list, "\(count) entries")
            for name in ["name-000", "name-025", "not-there"] {
                XCTAssertEqual(try open.openName(name).encode(), try OpenFolder(list).openName(name).encode(), name)
            }
        }
        // Entries out of order are no list, read either way. A list's bytes are
        // its entries' bytes, one after another.
        var unsorted: [UInt8] = []
        for number in [2, 1] {
            unsorted += try FolderList(entries: [entry(number)]).encode()
        }
        assertFails(try FolderList(decoding: unsorted))
        assertFails(try OpenFolder(decoding: unsorted))
    }
}
