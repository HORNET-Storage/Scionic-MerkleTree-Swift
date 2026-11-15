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

#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

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
/// `lend` and `readInto` too.
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

    /// Reads what is kept under `hash` into `into`, when it is as long as `into`
    /// is, and says how long it is: nil when nothing is kept. A thing of another
    /// length is not read, and `into` is left as it was.
    ///
    /// The library reads chunks this way where it holds them a while: to send
    /// them, or to read several at once. Their lists say how long they are, so
    /// they are read one after another into memory that serves one batch after
    /// another. A store on disk should have its own, which looks at how long a
    /// thing is before it reads any of it, and reads it straight into `into`.
    /// Unless a store has its own, this asks `lend` and copies what is lent.
    func readInto(_ kind: Stored, _ hash: Hash, _ into: UnsafeMutableRawBufferPointer) throws -> UInt64?

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

    public func readInto(_ kind: Stored, _ hash: Hash, _ into: UnsafeMutableRawBufferPointer) throws -> UInt64? {
        var length: UInt64?
        let held = try lend(kind, hash) { bytes in
            length = UInt64(bytes.count)
            if bytes.count == into.count {
                into.copyMemory(from: bytes)
            }
        }
        return held ? length : nil
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
func checkChunk(_ item: ChunkRef, _ bytes: ArraySlice<UInt8>, _ what: String) throws {
    guard bytes.count == Int(item.length) else {
        throw ScionicError.sizeMismatch(what: what, expected: UInt64(item.length), actual: UInt64(bytes.count))
    }
    guard Hash.of(bytes) == item.hash else {
        throw ScionicError.hashMismatch(what: what)
    }
}

/// Whether `bytes`, which are lent, are the chunk that `item` names.
func checkChunk(_ item: ChunkRef, _ bytes: UnsafeRawBufferPointer, _ what: String) throws {
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
        try checkStoredChunk(item, bytes)
        try body(bytes)
    }
}

/// Holds bytes read from a store to the chunk that `item` names. Bytes that do
/// not hash to the chunk's hash are damaged. Bytes that do, and are not as many
/// as the item says, show that the item is wrong.
private func checkStoredChunk(_ item: ChunkRef, _ bytes: UnsafeRawBufferPointer) throws {
    guard Hash.of(bytes) == item.hash else {
        throw damaged("a stored chunk", item.hash)
    }
    guard bytes.count == Int(item.length) else {
        throw ScionicError.sizeMismatch(what: "a stored chunk", expected: UInt64(item.length), actual: UInt64(bytes.count))
    }
}

/// The most bytes of chunks that are read ahead of what is done with them.
private let aheadBytes: UInt64 = 64 << 20

/// The most chunks that are read ahead, however short.
private let aheadCount = 1024

/// The least bytes of chunks that are worth a thread of their own.
private let aheadBytesByEach: UInt64 = 1 << 20

/// How chunks are read ahead.
private enum Ahead {
    /// Checked, as `lendChunk` checks them.
    case checked
    /// As frames to send, as the store holds them: whoever takes them checks
    /// them.
    case framed
}

/// How many bytes a chunk takes when it is read ahead as `ahead` says.
private func slotLength(_ item: ChunkRef, _ ahead: Ahead) -> Int {
    Int(item.length) + (ahead == .framed ? 1 : 0)
}

/// Reads the chunk that `item` names into `slot`, which is as long as
/// `slotLength` gives, as `ahead` says, and says whether the store holds it. A
/// chunk that the store holds with another length than `item` gives is not
/// read into `slot`. Read to be checked, it is lent and checked whole instead,
/// which tells whether it is damaged or `item` is wrong. Read to be sent, it is
/// not held: it cannot be the chunk.
private func readSlot(_ store: any Store, _ item: ChunkRef, _ ahead: Ahead, _ slot: UnsafeMutableRawBufferPointer) throws -> Bool {
    let length = UInt64(item.length)
    switch ahead {
    case .checked:
        switch try store.readInto(.chunk, item.hash, slot) {
        case nil:
            return false
        case length?:
            try checkStoredChunk(item, UnsafeRawBufferPointer(slot))
            return true
        case _?:
            guard try lendChunk(store, item, to: { _ in }) else {
                return false
            }
            throw ScionicError.invariant("a store gave two lengths for one chunk")
        }
    case .framed:
        guard !slot.isEmpty else {
            throw ScionicError.invariant("a chunk's frame has no room for its tag")
        }
        slot[0] = FrameTag.chunk
        return try store.readInto(.chunk, item.hash, UnsafeMutableRawBufferPointer(rebasing: slot[1...])) == length
    }
}

/// Memory that the chunks of a batch are read into, one after another. It is
/// cleared when it is taken, so that nothing that was in this memory before is
/// ever read out of it.
private final class AheadMemory: @unchecked Sendable {
    private(set) var bytes = UnsafeMutableRawBufferPointer(start: nil, count: 0)

    deinit {
        free(bytes.baseAddress)
    }

    /// The first `count` bytes. Where more are needed than are held, fresh
    /// memory is taken: what was held is not needed then. It is taken cleared
    /// from the system, which clears memory it has not handed out before as
    /// it is first written, by the thread that writes it: clearing it all here,
    /// on one thread, would hold up every thread that reads into it.
    func room(_ count: Int) throws -> UnsafeMutableRawBufferPointer {
        if bytes.count < count {
            free(bytes.baseAddress)
            bytes = UnsafeMutableRawBufferPointer(start: nil, count: 0)
            guard let fresh = calloc(count, 1) else {
                throw ScionicError.allocationFailed(resource: "chunks read ahead", requested: UInt64(count))
            }
            bytes = UnsafeMutableRawBufferPointer(start: fresh, count: count)
        }
        return UnsafeMutableRawBufferPointer(rebasing: bytes[..<count])
    }
}

/// Reads chunks from a store ahead of what is done with them, several at once.
/// The chunks of a batch are read one after another into one stretch of memory,
/// each into as many bytes as its list gives it, and that memory serves one
/// batch after another: memory that is used again costs much less than fresh
/// memory. It is no longer than the longest batch, whatever the lengths of the
/// chunks of the batches before.
final class ChunksAhead {
    private let memory = AheadMemory()
    private let threads: Int

    /// Reads with up to `threads` threads at once; zero is one for each core.
    init(threads: Int = 0) {
        self.threads = threads == 0 ? processorCount() : max(threads, 1)
    }

    /// How many bytes of memory this holds for chunks.
    var memoryHeld: Int {
        memory.bytes.count
    }

    /// Lends the chunks that `items` name to `body`, each with its place among
    /// them, in their order. Each is read from the store and checked first, as
    /// `lendChunk` checks it. Where the chunks are long enough to be worth it,
    /// several are read and checked at once, ahead of `body`; otherwise each is
    /// lent straight from the store. The first chunk that is missing or damaged
    /// is the error, and `body` is given neither it nor any after it.
    func lend(_ store: any Store, _ items: ArraySlice<ChunkRef>, to body: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        try inBatches(items) { first, batch, workers in
            if workers <= 1 {
                for (index, item) in batch.enumerated() {
                    guard try lendChunk(store, item, to: { try body(first + index, $0) }) else {
                        throw missing("the chunk", item.hash)
                    }
                }
                return true
            }
            let (read, slots) = try severalAtOnce(store, batch, .checked, workers)
            for (index, item) in batch.enumerated() {
                guard try read[index].get() else {
                    throw missing("the chunk", item.hash)
                }
                try body(first + index, UnsafeRawBufferPointer(slots[index]))
            }
            return true
        }
    }

    /// Gives `body` the frames of the chunks that `items` name, in their order,
    /// lent for the call only and read from the store as it holds them: whoever
    /// takes them checks them. Where the chunks are long enough to be worth it,
    /// several are read at once, ahead of `body`. A chunk that the store does
    /// not hold, or holds with another length than its item gives, is given as
    /// nil, and nothing after it.
    func frames(_ store: any Store, _ items: ArraySlice<ChunkRef>, to body: (UnsafeRawBufferPointer?) throws -> Void) throws {
        try inBatches(items) { _, batch, workers in
            if workers <= 1 {
                for item in batch {
                    let slot = try memory.room(slotLength(item, .framed))
                    guard try readSlot(store, item, .framed, slot) else {
                        try body(nil)
                        return false
                    }
                    try body(UnsafeRawBufferPointer(slot))
                }
                return true
            }
            let (read, slots) = try severalAtOnce(store, batch, .framed, workers)
            for index in 0..<batch.count {
                guard try read[index].get() else {
                    try body(nil)
                    return false
                }
                try body(UnsafeRawBufferPointer(slots[index]))
            }
            return true
        }
    }

    /// Hands `body` each batch of `items` that is read ahead at once: the place
    /// of its first item among them, its items, and how many threads read them.
    /// A batch holds up to 64 MiB of chunks, and up to 1024 of them. It stops
    /// where `body` says so.
    private func inBatches(_ items: ArraySlice<ChunkRef>, _ body: (Int, ArraySlice<ChunkRef>, Int) throws -> Bool) rethrows {
        var first = items.startIndex
        while first < items.endIndex {
            var count = 0
            var bytes: UInt64 = 0
            for item in items[first...].prefix(aheadCount) {
                if count > 0 && bytes + UInt64(item.length) > aheadBytes {
                    break
                }
                bytes += UInt64(item.length)
                count += 1
            }
            let workers = min(threads, Int(bytes / aheadBytesByEach) + 1, count)
            guard try body(first - items.startIndex, items[first..<(first + count)], workers) else {
                return
            }
            first += count
        }
    }

    /// Reads the chunks of `batch` on `workers` threads, each into its own part
    /// of the memory, and says for each whether the store holds it.
    private func severalAtOnce(
        _ store: any Store,
        _ batch: ArraySlice<ChunkRef>,
        _ ahead: Ahead,
        _ workers: Int
    ) throws -> (read: [Result<Bool, any Error>], slots: [UnsafeMutableRawBufferPointer]) {
        let lengths = batch.map { slotLength($0, ahead) }
        var rest = try memory.room(lengths.reduce(0, +))
        let slots = lengths.map { length -> UnsafeMutableRawBufferPointer in
            defer { rest = UnsafeMutableRawBufferPointer(rebasing: rest[length...]) }
            return UnsafeMutableRawBufferPointer(rebasing: rest[..<length])
        }
        let shared = Unchecked((slots: slots, batch: batch, ahead: ahead))
        let dealer = Dealer(count: batch.count)
        let read = Shared([Result<Bool, any Error>?](repeating: nil, count: batch.count))
        onWorkers(workers) { _ in
            while let index = dealer.take() {
                let item = shared.value.batch[shared.value.batch.startIndex + index]
                let result = Result { try readSlot(store, item, shared.value.ahead, shared.value.slots[index]) }
                read.with { $0[index] = result }
            }
        }
        return (read.with { $0 }.map { $0 ?? .failure(ScionicError.invariant("a chunk was left unread")) }, slots)
    }
}
