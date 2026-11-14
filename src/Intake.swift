// Taking a tree in, and checking a tree that is held.
//
// There is one set of checks, and it is here. A tree that arrives from a peer,
// a tree read from a bundle and a tree that already sits in a store all go
// through an `Intake`:
//
// * the record must hash to the root that was asked for;
// * a list is taken only when a list that is already checked names it, and
//   only when it has the hash, the size and the chunk lengths it has to;
// * a chunk is taken only when a file's list that is already checked names it,
//   and only with the bytes and the length that list gives it;
// * at the end nothing may be missing, folders may not sit too deep, and the
//   record's totals must be those of the tree.
//
// So parents come first, and nothing is kept before it is tied to the root. A
// frame never says which hash it belongs under. Its hash is worked out from its
// bytes.

/// The most chunks one request asks for.
private let chunksPerRequest: UInt32 = 64

/// What a frame turned out to be, once its hash was worked out.
public enum Arrived: Hashable, Sendable {
    case record
    case folderList(Hash)
    case fileList(Hash)
    case chunk(Hash)
}

/// What became of a frame that an intake accepted.
public struct Accepted: Hashable, Sendable {
    public let what: Arrived
    /// Whether it was kept now. It is not when it was held already.
    public let kept: Bool
}

/// A tree that is whole and checked.
public struct Summary: Hashable, Sendable {
    public let record: Record
    /// How many different folders the tree has.
    public let folders: UInt64
    /// How many different files the tree has.
    public let files: UInt64
}

/// How a held tree is checked, beyond what is always checked.
public struct VerifyOptions: Hashable, Sendable {
    /// Also chunks every file's bytes again, and refuses a file whose list is not
    /// the one the chunker gives. With this, the same bytes always have the same
    /// file hash. It costs one more pass over the bytes.
    public var rechunk: Bool
    /// Removes from the store what is damaged there: a chunk, a list or a record
    /// whose bytes are not what its hash says. The check then ends with one of
    /// them as missing, and a fetch of the tree brings them all again. Without
    /// this the check stops at a damaged thing and names it, and the store is
    /// left as it is.
    public var discardDamaged: Bool
    /// How many chunks are hashed at once. Zero is one for each core.
    public var workers: Int

    public init(rechunk: Bool = false, discardDamaged: Bool = false, workers: Int = 0) {
        self.rechunk = rechunk
        self.discardDamaged = discardDamaged
        self.workers = workers
    }
}

struct Mode {
    /// Chunk again the files that are held whole.
    var rechunk = false
    /// Remove from the store what is damaged there, and want it again.
    var discard = false
}

private struct FolderSlot {
    var size: UInt64
    var order: UInt64
    var held: Bool
    /// The folders directly inside this one.
    var inside: [Hash]
}

private struct FileSlot {
    var size: UInt64
    var order: UInt64
    var held: Bool
}

/// Where a chunk was first listed: the file, by the order it was named in, and
/// the chunk's number there.
struct Place: Hashable, Comparable {
    let order: UInt64
    let number: UInt64

    static func < (a: Place, b: Place) -> Bool {
        (a.order, a.number) < (b.order, b.number)
    }
}

private struct ChunkSlot {
    var length: UInt32
    /// Where the chunk was first listed, while it is not held.
    var wantedAt: Place?
}

func saturatingAdd(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

func saturatingMultiply(_ a: Int, _ b: Int) -> Int {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? Int.max : product
}

/// Takes one tree into a store, checking every part as it arrives.
///
/// An intake is given frames in any order that puts parents first. What the
/// store holds already is found when it is named, and is not asked for.
///
/// A frame that is refused at the door leaves the intake as it was: one that
/// nothing names, one that is malformed, one that was not asked for. A list that
/// is named and then fails a check shows that the tree itself is wrong. The list
/// is not kept, and the intake is done: every later call gives
/// `ScionicError.intakeFailed`. A new intake picks up from what the store holds.
///
/// What the store holds under a hash and is not what the hash says is damaged.
/// An intake removes it from the store and wants it again, so a tree that was
/// harmed where it is kept is made whole by fetching it once more. Nothing a
/// peer sends can make an intake remove what is sound.
public final class Intake {
    let store: any Store
    public let root: Root
    private let mode: Mode
    /// The tree's record, once it is in. Its totals say how much the tree will
    /// take before any of it is taken, and an intake stops as soon as a tree
    /// turns out to hold more than its record says.
    public private(set) var record: Record?
    /// How the files are chunked, for a tree that has no record yet.
    private var measuring: Chunking?
    private var folders: [Hash: FolderSlot] = [:]
    private var files: [Hash: FileSlot] = [:]
    private var chunks: [Hash: ChunkSlot] = [:]
    /// Lists that are named and not held, in the order they were named.
    private var wantedLists = SortedMap<UInt64, Target>()
    /// Chunks that are named and not held, by where they were first listed.
    private var wantedChunks = SortedMap<Place, Hash>()
    private var fileByOrder: [UInt64: Hash] = [:]
    private var nextOrder: UInt64 = 0
    private(set) var counted = Totals()
    private var pending: [Target] = []
    /// The files to chunk again, once their chunks are hashed.
    private var toRechunk: [Hash] = []
    private var chunker: StreamChunker?
    /// A step that changes what the intake knows failed half way.
    private var failed = false

    /// Starts taking in the tree with this root. If the store holds the tree's
    /// record, everything else it holds of the tree is found now.
    public convenience init(store: any Store, root: Root) throws {
        try self.init(store: store, root: root, mode: Mode(rechunk: false, discard: true))
    }

    private init(bare store: any Store, root: Root, mode: Mode) {
        self.store = store
        self.root = root
        self.mode = mode
    }

    convenience init(store: any Store, root: Root, mode: Mode) throws {
        self.init(bare: store, root: root, mode: mode)
        let held: Record?
        do {
            held = try loadRecord(store, root)
        } catch ScionicError.corrupt where mode.discard {
            // A record that is damaged where it is kept is fetched again.
            try store.remove(.record, root.hash)
            held = nil
        }
        if let held {
            try begin(held)
        }
    }

    /// Checks every list under `top` as an intake checks it, for a tree that has
    /// no record yet, and counts what its record has to say: each different
    /// chunk and each different list, once. The store must hold every list.
    /// This is how a builder comes by a record's totals, so a tree that is built
    /// has passed the checks of a tree that is taken in.
    static func measure(_ store: any Store, top: Target, chunking: Chunking) throws -> Totals {
        let intake = Intake(bare: store, root: Root(hash: .zero), mode: Mode())
        intake.measuring = chunking
        try intake.refer(top)
        try intake.drain()
        try intake.listsHeld()
        try intake.checkDepth(top)
        return intake.counted
    }

    /// How many lists and chunks are named and not held yet. The record counts
    /// as one while it is not in.
    public var outstanding: Int {
        (record == nil ? 1 : 0) + wantedLists.count + wantedChunks.count
    }

    /// How many bytes of lists the record still leaves room for.
    private var listsLeft: Int {
        guard let record else {
            return 0
        }
        let (left, overflow) = record.totals.listBytes.subtractingReportingOverflow(counted.listBytes)
        return overflow ? 0 : Int(clamping: left)
    }

    /// The longest chunk the tree's way of chunking allows.
    private var longestChunk: Int {
        record?.chunking.fixedSize.map(Int.init) ?? Scionic.maxChunkBytes
    }

    /// The longest frame that a stream of this tree can hold, whatever comes
    /// next: for a reader of a stream that was not asked frame by frame, as a
    /// bundle is. Before the record it is the longest record. After it, it is
    /// the longest of a record, a chunk, and all the bytes of lists that the
    /// record gives the tree. What the store holds already may come too, and is
    /// passed over, so this does not shrink as lists come.
    public var frameLimit: Int {
        guard let record else {
            return Scionic.maxRecordBytes
        }
        let longest = max(Int(clamping: record.totals.listBytes), longestChunk)
        return max(saturatingAdd(longest, 1), Scionic.maxRecordBytes)
    }

    /// The longest frame that can answer one of this intake's requests. A peer
    /// that sends a longer one is not answering what was asked, and its frame
    /// need not be read: a file's list is no longer than the file's size allows,
    /// no list is longer than the record leaves room for, and a chunk is no
    /// longer than the tree's way of chunking allows.
    public func answerLimit(_ request: Request) -> Int {
        let limit: Int
        switch request {
        case .record:
            limit = Scionic.maxRecordBytes
        case .folder:
            limit = saturatingAdd(listsLeft, 1)
        case let .file(file):
            var most: UInt64 = 0
            if let record, let slot = files[file] {
                most = record.chunking.countBounds(size: slot.size).most
            }
            limit = saturatingAdd(min(saturatingMultiply(Int(clamping: most), Scionic.listItemBytes), listsLeft), 1)
        case .chunks, .chunk:
            limit = longestChunk + 1
        default:
            limit = 0
        }
        // A refusal takes two bytes, and is always let through.
        return max(limit, 2)
    }

    private func begin(_ record: Record) throws {
        self.record = record
        try refer(record.top)
        try drain()
    }

    private func recorded() throws -> Record {
        guard let record else {
            throw ScionicError.notWanted(what: "a frame that comes before the record")
        }
        return record
    }

    /// How the tree's files are chunked.
    private func chunking() throws -> Chunking {
        if let measuring {
            return measuring
        }
        return try recorded().chunking
    }

    /// Every list that is named has to be held.
    private func listsHeld() throws {
        if let (_, target) = wantedLists.first {
            throw missing(target.kind == .folder ? "the list of the folder" : "the list of the file", target.hash)
        }
    }

    /// The store holds, under `hash`, bytes that are not what the hash says.
    /// They are removed when this intake may do that, so that they are wanted
    /// again. Otherwise they are an error that names them.
    private func damaged(_ kind: Stored, _ hash: Hash, _ what: String) throws {
        if mode.discard {
            try store.remove(kind, hash)
        } else {
            throw ScionicError.corrupt(what: what, hash: hash)
        }
    }

    /// Whether the store holds the chunk that `item` names. The chunk's bytes
    /// are counted here, not hashed.
    private func holds(_ item: ChunkRef) throws -> Bool {
        guard let size = try store.size(.chunk, item.hash) else {
            return false
        }
        if size == UInt64(item.length) {
            return true
        }
        // Either the store's bytes are damaged, or the list gives the chunk a
        // length it does not have. Only damaged bytes are ever removed: a list
        // that names a sound chunk wrongly must not cost the store it.
        guard let bytes = try store.get(.chunk, item.hash) else {
            return false
        }
        if Hash.of(bytes) == item.hash {
            throw ScionicError.sizeMismatch(what: "a held chunk", expected: UInt64(item.length), actual: size)
        }
        try damaged(.chunk, item.hash, "a stored chunk")
        return false
    }

    /// Notes that a checked parent names `target`.
    private func refer(_ target: Target) throws {
        let known = target.kind == .folder ? folders[target.hash]?.size : files[target.hash]?.size
        if let size = known {
            guard size == target.size else {
                throw ScionicError.sizeMismatch(what: "a file or folder that is named twice", expected: size, actual: target.size)
            }
            return
        }
        let order = nextOrder
        nextOrder += 1
        switch target.kind {
        case .folder:
            folders[target.hash] = FolderSlot(size: target.size, order: order, held: false, inside: [])
        case .file:
            files[target.hash] = FileSlot(size: target.size, order: order, held: false)
            fileByOrder[order] = target.hash
        }
        pending.append(target)
    }

    /// Looks in the store for every list that was newly named. A list that is
    /// there is checked like one that arrives, and the lists it names are looked
    /// for in turn. A list that is not there is wanted, and so is one that is
    /// damaged there.
    private func drain() throws {
        while let target = pending.popLast() {
            switch target.kind {
            case .folder:
                guard let bytes = try store.get(.folderList, target.hash) else {
                    want(target)
                    continue
                }
                if let list = try? FolderList(decoding: bytes), list.hash == target.hash {
                    try admitFolder(list)
                } else {
                    try damaged(.folderList, target.hash, "a stored folder's list")
                    want(target)
                }
            case .file:
                guard let bytes = try store.get(.fileList, target.hash) else {
                    want(target)
                    continue
                }
                if let list = try? FileList(decoding: bytes), list.hash == target.hash {
                    try admitFile(list)
                } else {
                    try damaged(.fileList, target.hash, "a stored file's list")
                    want(target)
                }
            }
        }
    }

    private func want(_ target: Target) {
        let order = target.kind == .folder ? folders[target.hash]?.order : files[target.hash]?.order
        if let order {
            wantedLists.insert(order, target)
        }
    }

    private func countListBytes(_ bytes: UInt64) throws {
        let (sum, overflow) = counted.listBytes.addingReportingOverflow(bytes)
        if overflow {
            throw ScionicError.sizeOverflow(field: "list bytes")
        }
        counted.listBytes = sum
        // A tree that is being measured has no record to be held to yet.
        guard let record else {
            return
        }
        if counted.listBytes > record.totals.listBytes {
            throw ScionicError.totalsMismatch(field: "list bytes", recorded: record.totals.listBytes, counted: counted.listBytes)
        }
    }

    private func countChunk(_ length: UInt32) throws {
        let (chunks, chunksOverflow) = counted.chunks.addingReportingOverflow(1)
        if chunksOverflow {
            throw ScionicError.sizeOverflow(field: "chunks")
        }
        let (bytes, bytesOverflow) = counted.chunkBytes.addingReportingOverflow(UInt64(length))
        if bytesOverflow {
            throw ScionicError.sizeOverflow(field: "chunk bytes")
        }
        counted.chunks = chunks
        counted.chunkBytes = bytes
        guard let record else {
            return
        }
        if counted.chunks > record.totals.chunks {
            throw ScionicError.totalsMismatch(field: "chunks", recorded: record.totals.chunks, counted: counted.chunks)
        }
        if counted.chunkBytes > record.totals.chunkBytes {
            throw ScionicError.totalsMismatch(field: "chunk bytes", recorded: record.totals.chunkBytes, counted: counted.chunkBytes)
        }
    }

    /// Takes a folder's list that is named, and notes what it names.
    private func admitFolder(_ list: FolderList) throws {
        guard var slot = folders[list.hash] else {
            throw ScionicError.invariant("a folder is admitted before it is named")
        }
        guard slot.size == list.size else {
            throw ScionicError.sizeMismatch(what: "a folder", expected: slot.size, actual: list.size)
        }
        slot.held = true
        var inside = list.entries.filter { $0.kind == .folder }.map(\.hash)
        inside.sort()
        slot.inside = inside.enumerated().filter { $0.offset == 0 || inside[$0.offset - 1] != $0.element }.map(\.element)
        folders[list.hash] = slot
        wantedLists.remove(slot.order)
        try countListBytes(list.encodedCount)
        for entry in list.entries {
            try refer(entry.target)
        }
    }

    /// Takes a file's list that is named, and notes the chunks it names.
    private func admitFile(_ list: FileList) throws {
        let chunking = try self.chunking()
        try list.checkChunking(chunking)
        guard var slot = files[list.hash] else {
            throw ScionicError.invariant("a file is admitted before it is named")
        }
        guard slot.size == list.size else {
            throw ScionicError.sizeMismatch(what: "a file", expected: slot.size, actual: list.size)
        }
        slot.held = true
        files[list.hash] = slot
        let order = slot.order
        wantedLists.remove(order)
        try countListBytes(list.encodedCount)
        for (number, item) in list.items.enumerated() {
            if let known = chunks[item.hash] {
                guard known.length == item.length else {
                    throw ScionicError.sizeMismatch(
                        what: "a chunk that is listed with two lengths",
                        expected: UInt64(known.length),
                        actual: UInt64(item.length)
                    )
                }
                continue
            }
            try countChunk(item.length)
            let wantedAt = try holds(item) ? nil : Place(order: order, number: UInt64(number))
            if let wantedAt {
                wantedChunks.insert(wantedAt, item.hash)
            }
            chunks[item.hash] = ChunkSlot(length: item.length, wantedAt: wantedAt)
        }
        if mode.rechunk && chunking == .fastCDCv1 {
            toRechunk.append(list.hash)
        }
    }

    /// Hashes again every chunk of this tree that the store holds, several at
    /// once. A chunk whose bytes are not what its hash says is damaged.
    fileprivate func rehashHeld(workers: Int) throws {
        let held = chunks.compactMap { hash, slot in
            slot.wantedAt == nil ? ChunkRef(hash: hash, length: slot.length) : nil
        }.sorted { $0.hash < $1.hash }
        let store = self.store
        let dealer = Dealer(count: held.count)
        let spoiled = Shared<[Int]>([])
        onWorkers(workerCount(workers, work: held.count)) { _ in
            while let index = dealer.take() {
                do {
                    let item = held[index]
                    guard let bytes = try store.get(.chunk, item.hash) else {
                        throw missing("the chunk", item.hash)
                    }
                    if !item.matches(bytes) {
                        spoiled.with { $0.append(index) }
                    }
                } catch {
                    dealer.fail(error)
                }
            }
        }
        try dealer.check()
        let places = spoiled.with { $0 }.sorted()
        for index in places {
            try damaged(.chunk, held[index].hash, "a stored chunk")
        }
        if let first = places.first {
            throw missing("the chunk", held[first].hash)
        }
    }

    /// Chunks again every file that is held whole, and holds the result against
    /// the file's list. The chunks were hashed before this.
    fileprivate func rechunkHeld() throws {
        let lists = toRechunk
        toRechunk = []
        for file in lists {
            guard let bytes = try store.get(.fileList, file) else {
                continue
            }
            let list = try FileList(decoding: bytes)
            let whole = list.items.allSatisfy { item in
                chunks[item.hash].map { $0.wantedAt == nil } ?? false
            }
            if whole {
                try rechunk(list)
            }
        }
    }

    /// Chunks a file's bytes again, and holds the result against its list.
    private func rechunk(_ list: FileList) throws {
        let chunker = self.chunker ?? StreamChunker()
        self.chunker = chunker
        let store = self.store
        var unread = list.items.makeIterator()
        var current: [UInt8] = []
        var at = 0
        var unchunked = list.items.makeIterator()
        let mischunked = invalid("the chunks of a file do not end where its bytes say they end")
        try chunker.cut(.fastCDCv1, room: 2 * Scionic.maxChunkBytes, read: { buffer in
            while true {
                if at < current.count {
                    let count = min(buffer.count, current.count - at)
                    current.withUnsafeBytes { bytes in
                        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[at..<(at + count)]))
                    }
                    at += count
                    return count
                }
                guard let item = unread.next() else {
                    return 0
                }
                guard let bytes = try store.get(.chunk, item.hash), bytes.count == Int(item.length) else {
                    throw missing("the chunk", item.hash)
                }
                current = bytes
                at = 0
            }
        }, onChunks: { pieces in
            for chunk in pieces {
                guard let item = unchunked.next(), Int(item.length) == chunk.count else {
                    throw mischunked
                }
            }
        })
        if unchunked.next() != nil {
            throw mischunked
        }
    }

    /// Takes one frame: a record, a whole list, or a chunk.
    ///
    /// A frame is accepted when it is what a checked parent names. A frame that
    /// is named and held already is accepted and not kept again. Any other frame
    /// is an error: one that nothing names, one that is malformed, and one that
    /// does not have the size it was given.
    @discardableResult
    public func accept(_ frame: [UInt8]) throws -> Accepted {
        try accept(frame, expected: nil)
    }

    /// Takes one frame, which has to be exactly `expected`: the answer to what
    /// was asked. Anything else is refused, and nothing of it is kept.
    @discardableResult
    public func accept(_ frame: [UInt8], expected: Arrived?) throws -> Accepted {
        if failed {
            throw ScionicError.intakeFailed
        }
        guard let tag = frame.first else {
            throw invalid("a frame is empty")
        }
        let body = frame[1...]
        func asAsked(_ arrived: Arrived, _ what: String) throws {
            if let expected, expected != arrived {
                throw ScionicError.notWanted(what: what)
            }
        }
        switch tag {
        case FrameTag.record:
            let what = Arrived.record
            try asAsked(what, "a record")
            guard Root.of(record: frame) == root else {
                throw ScionicError.hashMismatch(what: "a record")
            }
            if record != nil {
                return Accepted(what: what, kept: false)
            }
            let decoded = try Record(decoding: frame)
            try store.put(.record, root.hash, frame)
            try taking { try $0.begin(decoded) }
            return Accepted(what: what, kept: true)
        case FrameTag.folderList:
            _ = try recorded()
            let list = try FolderList(decoding: Array(body))
            let what = Arrived.folderList(list.hash)
            try asAsked(what, "a folder's list")
            guard let slot = folders[list.hash] else {
                throw ScionicError.notWanted(what: "a folder's list")
            }
            if slot.held {
                return Accepted(what: what, kept: false)
            }
            guard slot.size == list.size else {
                throw ScionicError.sizeMismatch(what: "a folder", expected: slot.size, actual: list.size)
            }
            // The list is kept only once all it says has passed.
            try taking { intake in
                try intake.admitFolder(list)
                try intake.store.put(.folderList, list.hash, body)
                try intake.drain()
            }
            return Accepted(what: what, kept: true)
        case FrameTag.fileList:
            _ = try recorded()
            let list = try FileList(decoding: Array(body))
            let what = Arrived.fileList(list.hash)
            try asAsked(what, "a file's list")
            guard let slot = files[list.hash] else {
                throw ScionicError.notWanted(what: "a file's list")
            }
            if slot.held {
                return Accepted(what: what, kept: false)
            }
            guard slot.size == list.size else {
                throw ScionicError.sizeMismatch(what: "a file", expected: slot.size, actual: list.size)
            }
            // The list is kept only once all it says has passed.
            try taking { intake in
                try intake.admitFile(list)
                try intake.store.put(.fileList, list.hash, body)
            }
            return Accepted(what: what, kept: true)
        case FrameTag.chunk:
            _ = try recorded()
            guard !body.isEmpty, body.count <= Scionic.maxChunkBytes else {
                throw invalid("a chunk does not hold 1 byte to 8 MiB")
            }
            let hash = Hash.of(body)
            let what = Arrived.chunk(hash)
            try asAsked(what, "a chunk")
            guard var slot = chunks[hash] else {
                throw ScionicError.notWanted(what: "a chunk")
            }
            guard let at = slot.wantedAt else {
                return Accepted(what: what, kept: false)
            }
            guard Int(slot.length) == body.count else {
                throw ScionicError.sizeMismatch(what: "a chunk", expected: UInt64(slot.length), actual: UInt64(body.count))
            }
            try store.put(.chunk, hash, body)
            slot.wantedAt = nil
            chunks[hash] = slot
            wantedChunks.remove(at)
            return Accepted(what: what, kept: true)
        default:
            throw invalid("a frame that no tree is taken in by")
        }
    }

    /// Runs a step that changes what the intake knows of its tree. If the step
    /// fails, the intake knows half of something, and is done.
    private func taking(_ step: (Intake) throws -> Void) throws {
        do {
            try step(self)
        } catch {
            failed = true
            throw error
        }
    }

    /// What to ask a peer for next: at most `limit` requests. The record comes
    /// first, then lists, then chunks by their file and their numbers. Nothing is
    /// asked for twice while it is still wanted, so the caller asks again only
    /// after the answers have come, or have failed to.
    public func requests(limit: Int) -> [Request] {
        if failed {
            return []
        }
        if record == nil {
            return [.record(root)]
        }
        var requests: [Request] = []
        wantedLists.forEach { _, target in
            if requests.count >= limit {
                return false
            }
            requests.append(target.kind == .folder ? .folder(target.hash) : .file(target.hash))
            return true
        }
        var span: (order: UInt64, start: UInt64, count: UInt32)?
        wantedChunks.forEach { place, _ in
            if let current = span, current.order == place.order,
               current.start + UInt64(current.count) == place.number, current.count < chunksPerRequest {
                span = (current.order, current.start, current.count + 1)
                return true
            }
            if let done = span {
                pushChunks(&requests, done)
                span = nil
            }
            if requests.count >= limit {
                return false
            }
            span = (place.order, place.number, 1)
            return true
        }
        if let done = span, requests.count < limit {
            pushChunks(&requests, done)
        }
        return requests
    }

    private func pushChunks(_ requests: inout [Request], _ span: (order: UInt64, start: UInt64, count: UInt32)) {
        if let file = fileByOrder[span.order] {
            requests.append(.chunks(file: file, start: span.start, count: span.count))
        }
    }

    /// What the answer to one of this intake's requests has to be: the frames,
    /// in order. A peer may send fewer chunks than were asked for, and never
    /// anything else.
    public func expected(_ request: Request) -> [Arrived] {
        switch request {
        case .record:
            return [.record]
        case let .folder(folder):
            return [.folderList(folder)]
        case let .file(file):
            return [.fileList(file)]
        case let .chunks(file, start, count):
            guard let order = files[file]?.order else {
                return []
            }
            let (end, overflow) = start.addingReportingOverflow(UInt64(count))
            let last = overflow ? UInt64.max : end
            var frames: [Arrived] = []
            var number = start
            while number < last, let hash = wantedChunks.get(Place(order: order, number: number)) {
                frames.append(.chunk(hash))
                number += 1
            }
            return frames
        default:
            return []
        }
    }

    /// No path from the top may pass through more folders than the format
    /// allows. A folder that sits at several places is measured once.
    private func checkDepth(_ top: Target) throws {
        guard top.kind == .folder else {
            return
        }
        let tooDeep = ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
        // How many folders the longest path down from a folder passes through,
        // that folder counted.
        var heights: [Hash: Int] = [:]
        var path: [(folder: Hash, next: Int)] = [(top.hash, 0)]
        while let last = path.last {
            let inside = folders[last.folder]?.inside ?? []
            if last.next < inside.count {
                let child = inside[last.next]
                path[path.count - 1].next += 1
                if let height = heights[child] {
                    if path.count + height > Scionic.maxFolderDepth {
                        throw tooDeep
                    }
                } else if path.count >= Scionic.maxFolderDepth {
                    throw tooDeep
                } else {
                    path.append((child, 0))
                }
            } else {
                heights[last.folder] = 1 + (inside.compactMap { heights[$0] }.max() ?? 0)
                path.removeLast()
            }
        }
    }

    /// Ends the intake. The tree must be whole: the record in, every list and
    /// every chunk held, no folder too deep, and the record's totals right.
    public func finish() throws -> Summary {
        if failed {
            throw ScionicError.intakeFailed
        }
        if let (_, hash) = wantedChunks.first, record != nil, wantedLists.isEmpty {
            throw missing("the chunk", hash)
        }
        return try finishLists()
    }

    /// Ends the intake as `finish` does, without asking that the chunks are
    /// held: every list must be there and right, and the totals are counted from
    /// the lists.
    func finishLists() throws -> Summary {
        if failed {
            throw ScionicError.intakeFailed
        }
        guard let record else {
            throw missing("the record of", root.hash)
        }
        try listsHeld()
        try checkDepth(record.top)
        let recorded = record.totals
        for (field, wanted, found) in [
            ("chunks", recorded.chunks, counted.chunks),
            ("chunk bytes", recorded.chunkBytes, counted.chunkBytes),
            ("list bytes", recorded.listBytes, counted.listBytes),
        ] where wanted != found {
            throw ScionicError.totalsMismatch(field: field, recorded: wanted, counted: found)
        }
        return Summary(record: record, folders: UInt64(folders.count), files: UInt64(files.count))
    }
}

/// Checks a whole tree that a store holds: every list, every chunk's bytes, the
/// depth of its folders and the totals in its record. It is the same set of
/// checks that a tree goes through when it is taken in.
///
/// The lists are checked first. Then every chunk is hashed again, several at
/// once, and last, when that is asked for, every file is chunked again.
public func verify(_ store: any Store, _ root: Root, options: VerifyOptions = VerifyOptions()) throws -> Summary {
    let intake = try Intake(store: store, root: root, mode: Mode(rechunk: options.rechunk, discard: options.discardDamaged))
    try intake.rehashHeld(workers: options.workers)
    try intake.rechunkHeld()
    return try intake.finish()
}
