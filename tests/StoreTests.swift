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
        // A store that holds other bytes under a chunk's hash.
        try store.put(.chunk, item.hash, bytes("wrong"))
        XCTAssertThrowsError(try loadChunk(store, item)) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
        try store.remove(.chunk, item.hash)
        try store.put(.chunk, item.hash, bytes("longer"))
        XCTAssertThrowsError(try loadChunk(store, item)) { error in
            guard case ScionicError.corrupt = error else {
                return XCTFail("\(error)")
            }
        }
        // The chunk itself, named by an item that gives it another length.
        try store.remove(.chunk, item.hash)
        try store.put(.chunk, item.hash, bytes("right"))
        XCTAssertThrowsError(try loadChunk(store, ChunkRef(hash: item.hash, length: 4))) { error in
            guard case ScionicError.sizeMismatch = error else {
                return XCTFail("\(error)")
            }
        }

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
}
