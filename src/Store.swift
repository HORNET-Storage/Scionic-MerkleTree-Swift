// Where a tree's parts are kept.
//
// A store keeps four kinds of thing, each found by its hash: chunks, the lists
// of files, the lists of folders, and records. Because a thing's hash covers
// only what the thing is, a chunk, a file or a folder that occurs in many trees
// is kept once.
//
// A store checks nothing: it keeps what it is given under the hash it is given.
// Everything that this library puts into a store is checked first, and
// everything it takes out is checked again before it is used.

/// The kinds of thing a store keeps.
public enum Stored: UInt8, Hashable, Sendable, Comparable, CaseIterable {
    /// A chunk's bytes, under the SHA-256 of them.
    case chunk
    /// A file's whole list, under the file's hash.
    case fileList
    /// A folder's whole list, under the folder's hash.
    case folderList
    /// A tree's record, under the tree's root.
    case record

    public static func < (a: Stored, b: Stored) -> Bool {
        a.rawValue < b.rawValue
    }
}

/// A place that keeps bytes under hashes. Several threads use a store at once.
///
/// A store that can say how long a thing is without reading it should have its
/// own `size`: a store on disk above all. Without it, seeing whether a chunk is
/// there takes a read of the whole chunk. A store on disk should have its own
/// `lend` too.
public protocol Store: AnyObject, Sendable {
    /// Keeps `bytes` under `hash`. Keeping what is kept already changes nothing.
    /// The bytes are lent for the call only: a store that keeps them keeps a
    /// copy.
    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws

    /// What is kept under `hash`, if anything.
    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]?

    /// Lends what is kept under `hash` to `body`, and says whether anything is
    /// kept: `body` is called once if it is, and not at all if it is not. The
    /// bytes are lent for that call only, and an error from `body` is what this
    /// throws.
    ///
    /// The library reads a tree's chunks this way. A store on disk should have
    /// its own, which reads into memory that it uses again: `get` gives fresh
    /// memory for every chunk, and some systems take longer to give that than
    /// the reading takes. Unless a store has its own, this asks `get`.
    func lend(_ kind: Stored, _ hash: Hash, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool

    /// Whether anything is kept under `hash`. Unless a store has its own, this
    /// asks how long the thing is, so a store that can say that without reading
    /// the bytes is not read.
    func has(_ kind: Stored, _ hash: Hash) throws -> Bool

    /// How many bytes are kept under `hash`.
    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64?

    /// Forgets what is kept under `hash`.
    func remove(_ kind: Stored, _ hash: Hash) throws
}

extension Store {
    public func has(_ kind: Stored, _ hash: Hash) throws -> Bool {
        try size(kind, hash) != nil
    }

    public func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        try get(kind, hash).map { UInt64($0.count) }
    }

    public func lend(_ kind: Stored, _ hash: Hash, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
        guard let bytes = try get(kind, hash) else {
            return false
        }
        try bytes.withUnsafeBytes(body)
        return true
    }

    /// Keeps `bytes` under `hash`.
    public func put(_ kind: Stored, _ hash: Hash, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try put(kind, hash, $0) }
    }

    /// Keeps `bytes` under `hash`.
    public func put(_ kind: Stored, _ hash: Hash, _ bytes: ArraySlice<UInt8>) throws {
        try bytes.withUnsafeBytes { try put(kind, hash, $0) }
    }
}

/// A store in memory.
public final class MemoryStore: Store, @unchecked Sendable {
    private struct Key: Hashable {
        let kind: Stored
        let hash: Hash
    }

    private let lock = Lock()
    private var things: [Key: [UInt8]] = [:]

    public init() {}

    public func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        let key = Key(kind: kind, hash: hash)
        if lock.withLock({ things[key] != nil }) {
            return
        }
        // Copied before the lock is taken, so that many threads put at once.
        let kept = Array(bytes)
        lock.withLock {
            if things[key] == nil {
                things[key] = kept
            }
        }
    }

    public func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        lock.withLock { things[Key(kind: kind, hash: hash)] }
    }

    public func has(_ kind: Stored, _ hash: Hash) throws -> Bool {
        lock.withLock { things[Key(kind: kind, hash: hash)] != nil }
    }

    public func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        lock.withLock { things[Key(kind: kind, hash: hash)].map { UInt64($0.count) } }
    }

    public func remove(_ kind: Stored, _ hash: Hash) throws {
        _ = lock.withLock { things.removeValue(forKey: Key(kind: kind, hash: hash)) }
    }

    /// How many things of `kind` are kept.
    public func count(_ kind: Stored) -> Int {
        lock.withLock { things.keys.filter { $0.kind == kind }.count }
    }

    /// How many bytes the things of `kind` hold together.
    public func bytes(_ kind: Stored) -> UInt64 {
        lock.withLock { things.reduce(0) { $0 + ($1.key.kind == kind ? UInt64($1.value.count) : 0) } }
    }

    /// The hashes of the things of `kind`, in order.
    public func hashes(_ kind: Stored) -> [Hash] {
        lock.withLock { things.keys.filter { $0.kind == kind }.map(\.hash) }.sorted()
    }
}

/// The store holds, under `hash`, bytes that are not what the hash says.
func damaged(_ what: String, _ hash: Hash) -> ScionicError {
    .corrupt(what: what, hash: hash)
}

func missing(_ what: String, _ hash: Hash) -> ScionicError {
    .missing(what: what, hash: hash)
}

/// The record of `root`, read from the store and checked against the root.
func loadRecord(_ store: any Store, _ root: Root) throws -> Record? {
    guard let bytes = try store.get(.record, root.hash) else {
        return nil
    }
    guard Root.of(record: bytes) == root else {
        throw damaged("a stored record", root.hash)
    }
    return try Record(decoding: bytes)
}

/// A list read from a store has to hold the bytes its parent gave it.
private func confirmSize(_ read: UInt64, _ wanted: Target, _ what: String) throws {
    guard read == wanted.size else {
        throw ScionicError.sizeMismatch(what: what, expected: wanted.size, actual: read)
    }
}

/// The list of the folder `folder`, read from the store and checked. Bytes that
/// are not a list with the folder's hash are damaged.
func loadFolder(_ store: any Store, _ folder: Target) throws -> FolderList? {
    try folder.require(.folder)
    guard let bytes = try store.get(.folderList, folder.hash) else {
        return nil
    }
    let what = "a stored folder's list"
    guard let list = try? FolderList(decoding: bytes), list.hash == folder.hash else {
        throw damaged(what, folder.hash)
    }
    try confirmSize(list.size, folder, what)
    return list
}

/// The list of the file `file`, read from the store and checked. Bytes that are
/// not a list with the file's hash are damaged.
func loadFile(_ store: any Store, _ file: Target) throws -> FileList? {
    try file.require(.file)
    guard let bytes = try store.get(.fileList, file.hash) else {
        return nil
    }
    let what = "a stored file's list"
    guard let list = try? FileList(decoding: bytes), list.hash == file.hash else {
        throw damaged(what, file.hash)
    }
    try confirmSize(list.size, file, what)
    return list
}

/// Whether `bytes` are the chunk that `item` names.
func checkChunk(_ item: ChunkRef, _ bytes: [UInt8], _ what: String) throws {
    guard bytes.count == Int(item.length) else {
        throw ScionicError.sizeMismatch(what: what, expected: UInt64(item.length), actual: UInt64(bytes.count))
    }
    guard Hash.of(bytes) == item.hash else {
        throw ScionicError.hashMismatch(what: what)
    }
}

/// Has `store` lend the thing under `hash` to `body`, and holds the store to what
/// `Store.lend` promises: one call when it says it holds the thing, and none
/// when it says it does not. An error from `body` is thrown whatever the store
/// does with it, so that no store can pass over a chunk that was found damaged.
func lent(_ store: any Store, _ kind: Stored, _ hash: Hash, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
    var calls = 0
    var failure: (any Error)?
    let held: Bool
    do {
        held = try store.lend(kind, hash) { bytes in
            calls += 1
            do {
                guard calls == 1 else {
                    throw ScionicError.invariant("a store lent one thing twice")
                }
                try body(bytes)
            } catch {
                if failure == nil {
                    failure = error
                }
                // What went wrong is kept here. The store is only told to stop.
                throw ScionicError.invariant("what a store lent was refused")
            }
        }
    } catch {
        throw failure ?? error
    }
    if let failure {
        throw failure
    }
    switch (held, calls) {
    case (true, 1):
        return true
    case (false, 0):
        return false
    case (true, _):
        throw ScionicError.invariant("a store said it held a thing, and lent nothing")
    case (false, _):
        throw ScionicError.invariant("a store lent a thing, and said it did not hold it")
    }
}

/// Lends the chunk that `item` names to `body`, read from the store and checked
/// first, and says whether the store holds it. Bytes that do not hash to the
/// chunk's hash are damaged. Bytes that do, and are not as many as the item
/// says, show that the item is wrong.
func lendChunk(_ store: any Store, _ item: ChunkRef, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
    try lent(store, .chunk, item.hash) { bytes in
        guard Hash.of(bytes) == item.hash else {
            throw damaged("a stored chunk", item.hash)
        }
        guard bytes.count == Int(item.length) else {
            throw ScionicError.sizeMismatch(what: "a stored chunk", expected: UInt64(item.length), actual: UInt64(bytes.count))
        }
        try body(bytes)
    }
}
