import XCTest
@testable import ScionicMerkleTree

/// A store that says how long a thing is, and counts how often a thing is read
/// from it.
private final class SizedStore: Store, @unchecked Sendable {
    let inner = MemoryStore()
    let reads = Shared(0)

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        reads.with { $0 += 1 }
        return try inner.get(kind, hash)
    }

    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        try inner.size(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

final class StoreTests: XCTestCase {
    func testAStoreKeepsEachKindApartAndEachThingOnce() throws {
        let store = MemoryStore()
        let hash = Hash.of(bytes("x"))
        try store.put(.chunk, hash, bytes("x"))
        try store.put(.chunk, hash, bytes("x"))
        XCTAssertEqual(store.count(.chunk), 1)
        XCTAssertEqual(store.bytes(.chunk), 1)
        XCTAssertTrue(try store.has(.chunk, hash))
        XCTAssertFalse(try store.has(.fileList, hash))
        XCTAssertEqual(try store.size(.chunk, hash), 1)
        XCTAssertNil(try store.size(.record, hash))
        XCTAssertEqual(try store.get(.chunk, hash), bytes("x"))
        XCTAssertEqual(store.hashes(.chunk), [hash])
        try store.remove(.chunk, hash)
        XCTAssertNil(try store.get(.chunk, hash))
    }

    func testAStoreThatSaysHowLongAThingIsIsNotReadToSeeWhatItHolds() throws {
        let store = SizedStore()
        let content = (0..<5000).map { UInt8($0 % 251) }
        let builder = Builder(store: store, chunking: try .fixed(16))
        let first = try builder.file(bytes: content)
        // Built again, every chunk and the list are there already. Seeing that
        // takes no read: for a store on disk, a read is the whole of a chunk.
        let again = try builder.file(bytes: content)
        XCTAssertEqual(again, first)
        XCTAssertGreaterThan(store.inner.count(.chunk), 100)
        XCTAssertEqual(store.reads.with { $0 }, 0)
        // And it is still asked rightly.
        XCTAssertFalse(try store.has(.chunk, Hash.of(bytes("not there"))))
        XCTAssertTrue(try store.has(.fileList, first.hash))
        XCTAssertFalse(try store.has(.folderList, first.hash))
    }

    func testWhatIsReadFromAStoreIsCheckedBeforeItIsUsed() throws {
        let store = MemoryStore()
        let item = try ChunkRef.of(bytes("right"))
        // How many times a chunk was handed on.
        var seen = 0
        // A store that holds other bytes under a chunk's hash.
        try store.put(.chunk, item.hash, bytes("wrong"))
        XCTAssertThrowsError(try lendChunk(store, item) { _ in seen += 1 }) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
        try store.remove(.chunk, item.hash)
        try store.put(.chunk, item.hash, bytes("longer"))
        XCTAssertThrowsError(try lendChunk(store, item) { _ in seen += 1 }) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
        // The chunk itself, named by an item that gives it another length.
        try store.remove(.chunk, item.hash)
        try store.put(.chunk, item.hash, bytes("right"))
        XCTAssertThrowsError(try lendChunk(store, ChunkRef(hash: item.hash, length: 4)) { _ in seen += 1 }) { error in
            guard case ScionicError.sizeMismatch = error else {
                return XCTFail("\(error)")
            }
        }

        // Nothing that failed a check was handed on.
        XCTAssertEqual(seen, 0)
        XCTAssertTrue(try lendChunk(store, item) { _ in seen += 1 })
        XCTAssertEqual(seen, 1)

        // A list kept under another list's hash.
        let list = try FileList(items: [item])
        let other = try FileList(items: [item, item])
        try store.put(.fileList, list.hash, other.encode())
        XCTAssertThrowsError(try loadFile(store, list.target)) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
        // The right list, asked for with another size than it has.
        try store.put(.fileList, other.hash, other.encode())
        var resized = other.target
        resized.size += 1
        XCTAssertThrowsError(try loadFile(store, resized)) { error in
            guard case ScionicError.sizeMismatch = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertNotNil(try loadFile(store, other.target))
        // A file's list is not found as a folder's.
        var asFolder = other.target
        asFolder.kind = .folder
        XCTAssertNil(try loadFolder(store, asFolder))
        XCTAssertThrowsError(try loadFile(store, asFolder))

        // A record kept under another root.
        let root = Root.of(record: bytes("one"))
        try store.put(.record, root.hash, bytes("two"))
        XCTAssertThrowsError(try loadRecord(store, root)) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testAStoreIsHeldToWhatLendingPromises() throws {
        let item = try ChunkRef.of(bytes("right"))
        // What lending a chunk gave, and what was handed on of it.
        func lend(calls: Int, says: Bool, passesOver: Bool, kept: String) -> (Result<Bool, any Error>, [[UInt8]]) {
            let store = LendingStore(calls: calls, says: says, passesOver: passesOver)
            try? store.put(.chunk, item.hash, bytes(kept))
            var seen: [[UInt8]] = []
            let lent = Result { try lendChunk(store, item) { seen.append(Array($0)) } }
            return (lent, seen)
        }
        func isInvariant(_ lent: Result<Bool, any Error>) -> Bool {
            if case .failure(ScionicError.invariant) = lent {
                return true
            }
            return false
        }
        // As promised: one call for what is held, and none for what is not.
        var (lent, seen) = lend(calls: 1, says: true, passesOver: false, kept: "right")
        XCTAssertEqual(try lent.get(), true)
        XCTAssertEqual(seen, [bytes("right")])
        XCTAssertEqual(try lend(calls: 0, says: false, passesOver: false, kept: "right").0.get(), false)
        // A second call is refused, and nothing of it is handed on.
        (lent, seen) = lend(calls: 2, says: true, passesOver: true, kept: "right")
        XCTAssertTrue(isInvariant(lent), "\(lent)")
        XCTAssertEqual(seen.count, 1)
        // Said to be held, and nothing lent; lent, and said not to be held.
        XCTAssertTrue(isInvariant(lend(calls: 0, says: true, passesOver: false, kept: "right").0))
        XCTAssertTrue(isInvariant(lend(calls: 1, says: false, passesOver: false, kept: "right").0))
        // Damaged bytes stay an error when the store passes over it, and are
        // never handed on.
        for passesOver in [false, true] {
            (lent, seen) = lend(calls: 1, says: true, passesOver: passesOver, kept: "wrong")
            guard case .failure(ScionicError.corrupt) = lent else {
                return XCTFail("\(lent)")
            }
            XCTAssertTrue(seen.isEmpty)
        }
    }
}

/// A store that lends as it is set to, rightly or not.
private final class LendingStore: Store, @unchecked Sendable {
    let inner = MemoryStore()
    /// How many times it hands a thing to `body`.
    let calls: Int
    /// Whether it says that it holds the thing.
    let says: Bool
    /// Whether it passes over an error that `body` throws.
    let passesOver: Bool

    init(calls: Int, says: Bool, passesOver: Bool) {
        self.calls = calls
        self.says = says
        self.passesOver = passesOver
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func lend(_ kind: Stored, _ hash: Hash, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
        let held = try inner.get(kind, hash) ?? []
        for _ in 0..<calls {
            do {
                try held.withUnsafeBytes(body)
            } catch {
                if !passesOver {
                    throw error
                }
            }
        }
        return says
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}
