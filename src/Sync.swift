// Syncing by file hash and chunk number.
//
// * A `Responder` answers a receiver's requests from a store.
// * `fetch` takes a whole tree from a peer into a store, from the top down, and
//   skips whatever the store holds already.
// * A `Remote` reads parts of a tree straight from a peer: one name in a
//   folder, a branch of entries, or a stretch of a file's bytes. It needs no
//   store, and takes nothing but the parts it is asked for.
// * `exportBundle` and `importBundle` carry a whole tree as one stream of
//   frames.
// * `serve` answers requests on a connection, and a `StreamPeer` asks them
//   there.
//
// Nothing is compared between the two sides. The receiver walks down from the
// root it trusts, and every answer is checked as it arrives against a hash that
// is already checked. An answer that is forged, that belongs somewhere else, or
// that was not asked for is refused. With each request goes the longest frame
// that can answer it, so a peer cannot make a receiver set aside more memory
// than the tree it trusts calls for.

/// The most requests `fetch` sends before it looks at what is still wanted.
private let requestsPerRound = 64

/// The most items of a list that one answer shows.
private let maxBranchItems: UInt64 = 16_384

/// The most chunks that one answer sends.
private let maxChunksPerAnswer: UInt64 = 256

/// The bytes of a branch's frame that are there whatever it shows: its first
/// byte, the list's count, the branch's start, how many items it shows, and how
/// many nodes it carries.
private let branchFixedBytes = 23



/// The most lists of one kind that a responder keeps, however short.
private let recentLists = 64

/// How many bytes of requests `serve` takes off a connection at once: more than
/// an asker may send ahead.
private let serveBufferBytes = 2 * Scionic.requestsAheadBytes

extension Scionic {
    /// How many bytes of requests a `StreamPeer` sends ahead of their answers,
    /// and the most that it may be told to. It is small on purpose. The other
    /// end answers one request before it reads the next, so requests that are
    /// sent ahead wait in the connection, and a connection that could not hold
    /// them would leave both ends waiting for each other. A connection over a
    /// network holds this much, and `serve` takes this much off a connection
    /// that holds nothing.
    public static let requestsAheadBytes = 2048
}

private func peerError(_ detail: String) -> ScionicError {
    .peer(detail)
}

private let otherKind = ScionicError.notWanted(what: "an answer of another kind than was asked for")
private let tooMuch = ScionicError.notWanted(what: "more than was asked for")

/// Refuses a frame that is longer than its asker takes.
private func within(_ limit: Int, _ frame: [UInt8]) throws {
    if frame.count > limit {
        throw ScionicError.limitExceeded(what: "a frame", limit: UInt64(max(limit, 0)), requested: UInt64(frame.count))
    }
}

/// `count` times `each`, and `more` on top, or the largest Int where that does
/// not fit.
private func timesPlus(_ count: UInt64, _ each: Int, _ more: Int) -> Int {
    if count > UInt64(Int.max - more) / UInt64(each) {
        return Int.max
    }
    return Int(count) * each + more
}

/// The longest frame that shows `entries` entries of a folder.
func folderBranchLimit(_ entries: UInt64) -> Int {
    timesPlus(entries, Scionic.maxEntryBytes, branchFixedBytes + Scionic.maxCarriedNodes * (42 + Scionic.maxNameBytes))
}

/// The longest frame that shows `items` items of a file's list.
func fileBranchLimit(_ items: UInt64) -> Int {
    timesPlus(items, Scionic.listItemBytes, branchFixedBytes + Scionic.maxCarriedNodes * 40)
}

/// The most chunks that `length` bytes of a file can lie in. All of them but the
/// first and the last lie in the stretch whole, and no chunk but a file's last is
/// shorter than the tree's way of chunking allows.
func mostChunksIn(_ chunking: Chunking, _ length: UInt64) -> UInt64 {
    let shortest = chunking.fixedSize.map(UInt64.init) ?? UInt64(FastCDC.minSize + 1)
    return length / shortest + 2
}

// MARK: - Peers

/// A request as it is sent, with the longest frame that its asker takes in
/// answer.
public struct Asked: Hashable, Sendable {
    public var request: [UInt8]
    public var limit: Int

    public init(request: [UInt8], limit: Int) {
        self.request = request
        self.limit = limit
    }
}

/// Something that answers requests: a connection to another machine, or a
/// `Responder` in this one. A peer is used by one thread at a time.
public protocol Peer: AnyObject {
    /// Sends one request, and hands each frame of the answer to `onFrame` in
    /// the order the frames come. An error from `onFrame` ends the answer, and
    /// is what `ask` throws.
    ///
    /// `limit` is the longest frame the asker takes in answer. A frame that is
    /// longer is an error, and a peer on a connection refuses it by its length,
    /// before any of it is read.
    func ask(_ request: [UInt8], limit: Int, onFrame: ([UInt8]) throws -> Void) throws

    /// Sends several requests, each with its limit, and hands each frame to
    /// `onFrame` with the place of the request that it answers. Answers come in
    /// the order of the requests.
    ///
    /// Unless a peer says otherwise, this asks one at a time. A peer on a
    /// connection sends requests ahead of their answers, and saves the waiting
    /// between them.
    func askAll(_ requests: [Asked], onFrame: (Int, [UInt8]) throws -> Void) throws
}

extension Peer {
    public func askAll(_ requests: [Asked], onFrame: (Int, [UInt8]) throws -> Void) throws {
        for (place, asked) in requests.enumerated() {
            try ask(asked.request, limit: asked.limit) { try onFrame(place, $0) }
        }
    }
}

// MARK: - Answering

/// The lists that were used last. Reading a list from the store and hashing it
/// takes a pass over the whole of it, so a list that was asked about is kept
/// for the next request. Lists are weighed by their items, and the ones used
/// longest ago go first.
private struct Recent<Value> {
    private var kept: [(hash: Hash, value: Value, items: UInt64)] = []

    mutating func get(_ hash: Hash) -> Value? {
        guard let at = kept.firstIndex(where: { $0.hash == hash }) else {
            return nil
        }
        let found = kept.remove(at: at)
        kept.append(found)
        return found.value
    }

    /// Keeps `value`, and lets go of older ones while there are more than
    /// `most` items or too many lists. The newest one always stays.
    mutating func keep(_ hash: Hash, _ value: Value, items: UInt64, most: UInt64) {
        kept.removeAll { $0.hash == hash }
        kept.append((hash, value, max(items, 1)))
        var total = kept.reduce(UInt64(0)) { $0 + $1.items }
        while kept.count > 1 && (total > most || kept.count > recentLists) {
            total -= kept.removeFirst().items
        }
    }
}

/// Answers requests from a store.
///
/// It answers for whatever the store holds, by hash. It gives what it has and
/// says so when it has nothing: a receiver never has to trust it, because a
/// receiver checks every answer.
///
/// One responder serves many threads at once.
public final class Responder: Peer, @unchecked Sendable {
    private let store: any Store
    /// How many items of lists are kept between requests, for each kind.
    private let recent: UInt64
    /// Whether a peer is told which chunks of a file are held here.
    private let have: Bool
    /// The files whose lists were read last.
    private let lists = Shared(Recent<FileList>())
    /// The files and the folders whose trees were built last. Showing a part
    /// of a long list needs its tree.
    private let files = Shared(Recent<OpenFile>())
    private let folders = Shared(Recent<OpenFolder>())

    /// A responder for what `store` holds.
    ///
    /// `recent` is how many items of lists are kept between requests, for each
    /// of the three kinds: files' lists, files' trees and folders' trees. A
    /// list that is not kept is read from the store and hashed again when it
    /// is next asked about, which takes a pass over the whole of it. An item
    /// kept costs some tens of bytes for a file and some hundreds for a folder.
    /// The list that was used last is kept whatever its length. Unless it is
    /// told otherwise, a responder keeps 2^18 items of each kind, which for
    /// files' lists stand for about half a terabyte of files.
    ///
    /// `have` is whether a peer is told which chunks of a file are held here.
    /// Telling takes a look into the store for every chunk of the file, so a
    /// responder that serves strangers may leave it off. It then answers such a
    /// request as it does for a file it does not hold.
    public init(_ store: any Store, recent: UInt64 = 1 << 18, have: Bool = true) {
        self.store = store
        self.recent = recent
        self.have = have
    }

    private func fileList(_ file: Hash) throws -> FileList? {
        if let list = lists.with({ $0.get(file) }) {
            return list
        }
        if let open = files.with({ $0.get(file) }) {
            return open.list
        }
        guard let bytes = try store.get(.fileList, file) else {
            return nil
        }
        guard let list = try? FileList(decoding: bytes), list.hash == file else {
            throw damaged("a stored file's list", file)
        }
        let most = recent
        lists.with { $0.keep(file, list, items: list.count, most: most) }
        return list
    }

    private func openFile(_ file: Hash) throws -> OpenFile? {
        if let open = files.with({ $0.get(file) }) {
            return open
        }
        // Looked up on its own: the lock is let go before the list is hashed,
        // so that other threads are not kept waiting.
        let listed = lists.with { $0.get(file) }
        let open: OpenFile
        if let listed {
            open = try OpenFile(listed)
        } else {
            guard let bytes = try store.get(.fileList, file) else {
                return nil
            }
            // Read and hashed once, for the list and for its tree.
            guard let decoded = try? OpenFile(decoding: bytes), decoded.list.hash == file else {
                throw damaged("a stored file's list", file)
            }
            open = decoded
        }
        let most = recent
        files.with { $0.keep(file, open, items: open.list.count, most: most) }
        return open
    }

    private func openFolder(_ folder: Hash) throws -> OpenFolder? {
        if let open = folders.with({ $0.get(folder) }) {
            return open
        }
        guard let bytes = try store.get(.folderList, folder) else {
            return nil
        }
        guard let open = try? OpenFolder(decoding: bytes), open.list.hash == folder else {
            throw damaged("a stored folder's list", folder)
        }
        let most = recent
        folders.with { $0.keep(folder, open, items: open.list.count, most: most) }
        return open
    }

    /// Answers one request. Each frame of the answer is handed to `onFrame`. A
    /// request that is malformed is an error. A request for something the store
    /// does not hold is answered with a refusal.
    public func answer(_ request: [UInt8], onFrame: ([UInt8]) throws -> Void) throws {
        let notHeld = refusedFrame(.notHeld)
        let outOfRange = refusedFrame(.outOfRange)
        switch try Request(decoding: request) {
        case let .record(root):
            try onFrame(try store.get(.record, root.hash) ?? notHeld)
        case let .folder(folder):
            try onFrame(try store.get(.folderList, folder).map(folderListFrame) ?? notHeld)
        case let .file(file):
            try onFrame(try store.get(.fileList, file).map(fileListFrame) ?? notHeld)
        case let .chunk(chunk):
            var frame: [UInt8] = []
            let held = try lent(store, .chunk, chunk) { frame = chunkFrame($0) }
            try onFrame(held ? frame : notHeld)
        case let .folderBranch(folder, start, count):
            guard let open = try openFolder(folder) else {
                return try onFrame(notHeld)
            }
            let total = open.list.count
            if total == 0 {
                return try onFrame(folderBranchFrame(.empty))
            }
            if start >= total {
                return try onFrame(outOfRange)
            }
            let end = min(total, start + min(UInt64(count), maxBranchItems))
            try onFrame(folderBranchFrame(try open.open(start: start, end: end)))
        case let .folderName(folder, name):
            guard let open = try openFolder(folder) else {
                return try onFrame(notHeld)
            }
            try onFrame(folderBranchFrame(try open.openName(bytes: name)))
        case let .fileBranch(file, start, count):
            guard let open = try openFile(file) else {
                return try onFrame(notHeld)
            }
            let total = open.list.count
            if start >= total {
                return try onFrame(outOfRange)
            }
            let end = min(total, start + min(UInt64(count), maxBranchItems))
            try onFrame(fileBranchFrame(try open.open(start: start, end: end)))
        case let .fileBytes(file, offset, length):
            guard let open = try openFile(file) else {
                return try onFrame(notHeld)
            }
            let size = open.list.size
            if offset >= size {
                return try onFrame(outOfRange)
            }
            let (first, after) = try open.chunksFor(offset: offset, length: min(length, size - offset))
            try onFrame(fileBranchFrame(try open.open(start: first, end: min(after, first + maxBranchItems))))
        case let .chunks(file, start, count):
            guard let list = try fileList(file) else {
                return try onFrame(notHeld)
            }
            if start >= list.count {
                return try onFrame(outOfRange)
            }
            let end = min(list.count, start + min(UInt64(count), maxChunksPerAnswer))
            // One frame is filled again for each chunk. Memory that is used
            // again costs much less than fresh memory for every chunk, which a
            // system has to find and clear first. A frame that the asker keeps
            // is copied before it is filled again.
            var frame: [UInt8] = []
            for item in list.items[Int(start)..<Int(end)] {
                let held = try lent(store, .chunk, item.hash) { bytes in
                    frame.removeAll(keepingCapacity: true)
                    frame.append(FrameTag.chunk)
                    frame.append(contentsOf: bytes)
                }
                guard held else {
                    return try onFrame(notHeld)
                }
                try onFrame(frame)
            }
        case let .have(file):
            guard have, let list = try fileList(file) else {
                return try onFrame(notHeld)
            }
            var map = try HaveMap(count: list.count)
            for (number, item) in list.items.enumerated() {
                if try store.has(.chunk, item.hash) {
                    try map.set(UInt64(number))
                }
            }
            try onFrame(haveFrame(map))
        }
    }

    public func ask(_ request: [UInt8], limit: Int, onFrame: ([UInt8]) throws -> Void) throws {
        try answer(request) { frame in
            try within(limit, frame)
            try onFrame(frame)
        }
    }
}

/// Asks for one frame. A refusal, no frame and more than one frame are errors.
private func askOne(_ peer: any Peer, _ request: Request, limit: Int) throws -> [UInt8] {
    var answer: [UInt8]?
    try peer.ask(request.encode(), limit: limit) { frame in
        if answer != nil {
            throw tooMuch
        }
        answer = frame
    }
    guard let frame = answer else {
        throw peerError("gave no answer")
    }
    if frame.first == FrameTag.refused {
        if case .refused(.outOfRange) = try Frame(decoding: frame) {
            throw peerError("says that what was asked for lies outside the list or the file")
        }
        throw peerError("does not hold what was asked for")
    }
    return frame
}

// MARK: - Fetching

/// Takes the whole tree with this root from a peer into a store.
///
/// It goes from the top down: the record, then each folder's entries and each
/// file's list, then the chunks, by their file and their numbers in it.
/// Whatever the store holds already is skipped by its hash, be it a chunk, a
/// file or a whole folder, and wherever it came from. Every answer has to be
/// exactly what was asked for, and is checked before it is kept.
///
/// A fetch that fails can be started again: it goes on from what the store
/// holds.
@discardableResult
public func fetch(_ store: any Store, _ root: Root, from peer: any Peer) throws -> Summary {
    let intake = try Intake(store: store, root: root)
    while true {
        let requests = intake.requests(limit: requestsPerRound)
        if requests.isEmpty {
            break
        }
        // What each answer has to be is settled before anything is sent.
        // Nothing that comes in one round changes it: a round asks for each
        // thing once.
        let expected = requests.map { intake.expected($0) }
        let asks = requests.map { Asked(request: $0.encode(), limit: intake.answerLimit($0)) }
        var taken = [Int](repeating: 0, count: requests.count)
        var refused = [Bool](repeating: false, count: requests.count)
        try peer.askAll(asks) { place, frame in
            guard requests.indices.contains(place) else {
                throw peerError("answered a request that was not sent")
            }
            if refused[place] {
                throw peerError("sent more after it refused")
            }
            if frame.first == FrameTag.refused {
                _ = try Frame(decoding: frame)
                refused[place] = true
                return
            }
            guard taken[place] < expected[place].count else {
                throw tooMuch
            }
            _ = try intake.accept(frame, expected: expected[place][taken[place]])
            taken[place] += 1
        }
        if taken.contains(0) {
            throw peerError("does not hold what the tree needs")
        }
    }
    return try intake.finish()
}

// MARK: - Reading from a peer

/// A branch of a folder's entries, as a peer showed it and as it was checked.
public struct Entries: Hashable, Sendable {
    /// How many entries the folder has in all.
    public let total: UInt64
    /// The place of the first entry here.
    public let start: UInt64
    public let entries: [Entry]
}

/// Reads parts of one tree straight from a peer, with nothing kept.
///
/// It starts from a root that the caller trusts. Each thing it hands back was
/// shown by the peer and checked against that root: an entry by its place in
/// its folder, and bytes by their place in their file.
public final class Remote {
    private let peer: any Peer
    public let root: Root
    public let record: Record

    /// Asks the peer for the record of `root`, and checks it.
    public init(peer: any Peer, root: Root) throws {
        let frame = try askOne(peer, .record(root), limit: Scionic.maxRecordBytes)
        guard Root.of(record: frame) == root else {
            throw ScionicError.hashMismatch(what: "a record")
        }
        self.record = try Record(decoding: frame)
        self.peer = peer
        self.root = root
    }

    /// What is under `name` in `folder`, or nil when the folder has no such
    /// name. Either answer is proven by the one entry the peer shows.
    public func entry(_ folder: Target, name: String) throws -> Entry? {
        try entry(folder, nameBytes: Array(name.utf8))
    }

    func entry(_ folder: Target, nameBytes name: [UInt8]) throws -> Entry? {
        try checkName(bytes: name)
        try folder.require(.folder)
        let frame = try askOne(peer, .folderName(folder: folder.hash, name: name), limit: folderBranchLimit(1))
        guard case let .folderBranch(branch) = try Frame(decoding: frame) else {
            throw otherKind
        }
        return try branch.check(folder: folder, nameBytes: name)
    }

    /// What is at `path` in the tree: names with `/` between them. One question
    /// is asked for each name on the way.
    public func lookup(_ path: String) throws -> Entry? {
        var current = record.top
        var found: Entry?
        for (foldersPassed, name) in path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).enumerated() {
            let name = Array(name)
            try checkName(bytes: name)
            if current.kind != .folder {
                return nil
            }
            if foldersPassed >= Scionic.maxFolderDepth {
                throw ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
            }
            guard let entry = try entry(current, nameBytes: name) else {
                return nil
            }
            current = entry.target
            found = entry
        }
        return found
    }

    /// Up to `count` entries of a folder, from place `start`. Fewer come back
    /// when the folder ends first, or when the peer gives fewer at a time. An
    /// empty folder gives none.
    public func entries(_ folder: Target, start: UInt64, count: UInt32) throws -> Entries {
        try folder.require(.folder)
        let request = Request.folderBranch(folder: folder.hash, start: start, count: count)
        let frame = try askOne(peer, request, limit: folderBranchLimit(UInt64(count)))
        guard case let .folderBranch(branch) = try Frame(decoding: frame) else {
            throw otherKind
        }
        try branch.check(folder: folder)
        if branch.count != 0 && (branch.start != start || branch.entries.count > Int(count)) {
            throw ScionicError.notWanted(what: "a branch that was not asked for")
        }
        return Entries(total: branch.count, start: branch.start, entries: branch.entries)
    }

    /// Writes `length` bytes of a file, from byte `offset`, to `sink`.
    ///
    /// The peer shows the branch of the file's list that holds the stretch, and
    /// that proves each chunk's number and the byte it starts at. Then the
    /// chunks are asked for by their numbers, and each is checked against the
    /// list before any of its bytes is written. Nothing else of the file is
    /// taken.
    public func read(_ file: Target, offset: UInt64, length: UInt64, to sink: any ByteSink) throws {
        try file.require(.file)
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end <= file.size else {
            throw invalid("a stretch of bytes is outside the file")
        }
        let chunking = record.chunking
        var at = offset
        while at < end {
            let request = Request.fileBytes(file: file.hash, offset: at, length: end - at)
            let frame = try askOne(peer, request, limit: fileBranchLimit(mostChunksIn(chunking, end - at)))
            guard case let .fileBranch(branch) = try Frame(decoding: frame) else {
                throw otherKind
            }
            let branchStart = try branch.check(file: file, chunking: chunking)
            let items = branch.items
            // The branch has to begin with the chunk that holds the first byte
            // still due, and may not reach past the chunk that holds the last.
            guard let firstItem = items.first else {
                throw ScionicError.notWanted(what: "a branch that does not hold the bytes asked for")
            }
            let beforeLast = items.dropLast().reduce(UInt64(0)) { $0 + UInt64($1.length) }
            let holdsFirst = branchStart <= at && at < branchStart + UInt64(firstItem.length)
            if !holdsFirst || branchStart + beforeLast >= end {
                throw ScionicError.notWanted(what: "a branch that does not hold the bytes asked for")
            }
            let chunks = Request.chunks(file: file.hash, start: branch.start, count: UInt32(clamping: items.count))
            // No chunk that is due is longer than the longest in the branch.
            let longest = items.map { Int($0.length) }.max() ?? 0
            var taken = 0
            var chunkStart = branchStart
            var refused = false
            try peer.ask(chunks.encode(), limit: longest + 1) { frame in
                if refused {
                    throw peerError("sent more after it refused")
                }
                switch try Frame(decoding: frame) {
                case .refused:
                    refused = true
                case let .chunk(bytes):
                    guard taken < items.count else {
                        throw tooMuch
                    }
                    let item = items[taken]
                    try checkChunk(item, Array(bytes), "a chunk")
                    let chunkEnd = chunkStart + UInt64(item.length)
                    let from = bytes.startIndex + Int(at - chunkStart)
                    let to = bytes.startIndex + Int(min(end, chunkEnd) - chunkStart)
                    do {
                        try bytes[from..<to].withUnsafeBytes { try sink.write($0) }
                    } catch {
                        throw streamFailure(error, "write a file's bytes")
                    }
                    at = min(end, chunkEnd)
                    chunkStart = chunkEnd
                    taken += 1
                default:
                    throw otherKind
                }
            }
            if taken == 0 {
                throw peerError("does not hold the chunks asked for")
            }
        }
    }

    /// Which chunks of a file the peer says it holds, one bit a chunk. This is
    /// what the peer says about itself: nothing proves it, and a chunk it claims
    /// is still checked when it comes. Only the number of chunks is held to what
    /// the file's size allows.
    public func have(_ file: Target) throws -> HaveMap {
        try file.require(.file)
        let chunking = record.chunking
        let most = chunking.countBounds(size: file.size).most
        let limit = saturatingAdd(Int(clamping: (most + 7) / 8), 9)
        let frame = try askOne(peer, .have(file.hash), limit: limit)
        guard case let .have(map) = try Frame(decoding: frame) else {
            throw otherKind
        }
        try chunking.checkCount(size: file.size, count: map.count)
        return map
    }
}

// MARK: - Bundles

/// Writes a whole tree to `sink` as one stream: the bundle's first bytes, the
/// record, and then every list and every chunk once, each after what names it.
/// `importBundle` reads it back.
public func exportBundle(_ store: any Store, _ root: Root, to sink: any ByteSink) throws {
    let record = try recordOf(store, root)
    do {
        try sink.write(Scionic.bundleMagic)
    } catch {
        throw streamFailure(error, "write a bundle")
    }
    try writeFrame(sink, record.encode())
    var files = Set<Hash>()
    var folders = Set<Hash>()
    var chunks = Set<Hash>()
    var pending = [record.top]
    while let target = pending.popLast() {
        switch target.kind {
        case .folder:
            if !folders.insert(target.hash).inserted {
                continue
            }
            let list = try folderOf(store, target)
            try writeFrame(sink, tag: FrameTag.folderList, body: list.encode())
            pending.append(contentsOf: list.entries.reversed().map(\.target))
        case .file:
            if !files.insert(target.hash).inserted {
                continue
            }
            let list = try fileOf(store, target)
            try writeFrame(sink, tag: FrameTag.fileList, body: list.encode())
            for item in list.items {
                if !chunks.insert(item.hash).inserted {
                    continue
                }
                let held = try lendChunk(store, item) { bytes in
                    try writeFrame(sink, tag: FrameTag.chunk, body: bytes)
                }
                guard held else {
                    throw missing("the chunk", item.hash)
                }
            }
        }
    }
    try flush(sink, "write a bundle")
}

/// Reads a bundle that `exportBundle` wrote, and takes the tree with this root
/// from it into a store. Every frame goes through the same checks as a frame
/// from a peer, and the tree must be whole when the stream ends. A frame for
/// something the store holds already is passed over. A frame that nothing in
/// the tree names is an error.
@discardableResult
public func importBundle(_ store: any Store, _ root: Root, from source: any ByteSource) throws -> Summary {
    var magic = [UInt8](repeating: 0, count: Scionic.bundleMagic.count)
    let notABundle = invalid("a stream does not start as a bundle does")
    do {
        try magic.withUnsafeMutableBytes { try readExactly(source, $0, endsEarly: notABundle) }
    } catch {
        throw streamFailure(error, "read a bundle")
    }
    guard magic == Scionic.bundleMagic else {
        throw notABundle
    }
    let intake = try Intake(store: store, root: root)
    // One buffer serves every frame of the bundle.
    var frame: [UInt8] = []
    reading: while true {
        switch try readNext(source, limit: intake.frameLimit, into: &frame) {
        case .frame:
            _ = try intake.accept(frame)
        case .end:
            throw invalid("a frame is empty")
        case .closed:
            break reading
        }
    }
    return try intake.finish()
}

// MARK: - Connections

/// A source that is read through a buffer of its own. Each read of the source
/// asks for as much as the buffer holds, and what was not asked for yet waits
/// here.
final class BufferedSource: ByteSource {
    private let source: any ByteSource
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0

    init(_ source: any ByteSource, capacity: Int) {
        self.source = source
        self.buffer = [UInt8](repeating: 0, count: max(capacity, 1))
    }

    func read(into out: UnsafeMutableRawBufferPointer) throws -> Int {
        if out.isEmpty {
            return 0
        }
        if start == end {
            // A read as long as the buffer goes straight through.
            if out.count >= buffer.count {
                return try readSome(source, out)
            }
            let count = try buffer.withUnsafeMutableBytes { try readSome(source, $0) }
            if count == 0 {
                return 0
            }
            start = 0
            end = count
        }
        let count = min(out.count, end - start)
        buffer.withUnsafeBytes { raw in
            out.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[start..<(start + count)]))
        }
        start += count
        return count
    }
}

/// Answers the requests that come in on a connection, until it ends.
///
/// A request comes as a frame does: its length in four bytes, and then its
/// bytes. The answer goes out as its frames, each with its length before it, and
/// then a length of zero. Requests are answered one at a time, in the order they
/// come, and the sink is flushed after each answer.
///
/// A request that is malformed or too long ends the serving with an error. What
/// is not held is answered with a refusal, and the serving goes on.
///
/// `serve` reads from the connection until it ends, and may read requests before
/// it answers the ones before them.
public func serve(_ store: any Store, from source: any ByteSource, to sink: any ByteSink) throws {
    // Requests are read through a buffer that holds more than an asker may send
    // ahead. What was sent ahead is taken off the connection as soon as the
    // connection hands it over, and waits here while its answers are written.
    // So a connection that holds nothing of its own leaves no two ends waiting
    // for each other.
    let input = BufferedSource(source, capacity: serveBufferBytes)
    let responder = Responder(store)
    var request: [UInt8] = []
    while true {
        switch try readNext(input, limit: Scionic.maxRequestBytes, into: &request) {
        case .frame:
            break
        case .end:
            throw invalid("a request is empty")
        case .closed:
            return
        }
        try responder.answer(request) { try writeFrame(sink, $0) }
        try writeEnd(sink)
        try flush(sink, "send an answer")
    }
}

/// A peer at the other end of a connection, where `serve` answers.
///
/// An answer that is left half read, because a frame of it was refused, leaves
/// the connection where nobody knows what comes next. Nothing more is asked on
/// it then: open a new one.
public final class StreamPeer: Peer {
    private let input: any ByteSource
    private let output: any ByteSink
    private let ahead: Int
    private var broken = false
    /// One buffer for every frame that is read, from answer to answer.
    private var frame: [UInt8] = []

    /// A peer of a connection: `input` is what the other end sends, and
    /// `output` is what it reads. The output is flushed once requests are
    /// written.
    ///
    /// `ahead` is how many bytes of requests are sent ahead of their answers,
    /// and never more than `Scionic.requestsAheadBytes`. Requests that are sent
    /// ahead save a wait for each answer, which is most of the time a fetch of
    /// many small files takes on a slow connection. While the other end answers
    /// the first of them, the rest have to wait somewhere: a connection over a
    /// network holds them, and `serve` takes them off a connection that holds
    /// nothing, into a buffer of its own.
    ///
    /// Zero sends one request at a time, and waits for its answer. It is for an
    /// answerer of another make, which reads one request at a time from a
    /// connection that holds nothing. With requests sent ahead there, this end
    /// would wait to send its next request while the other end waits to send
    /// its first answer, for ever.
    public init(input: any ByteSource, output: any ByteSink, ahead: Int = Scionic.requestsAheadBytes) {
        self.input = input
        self.output = output
        self.ahead = min(max(ahead, 0), Scionic.requestsAheadBytes)
    }

    public func ask(_ request: [UInt8], limit: Int, onFrame: ([UInt8]) throws -> Void) throws {
        try askAll([Asked(request: request, limit: limit)]) { _, frame in
            try onFrame(frame)
        }
    }

    /// Sends requests ahead of their answers, as far as `ahead` lets it, and
    /// reads the answers in the order of the requests. A request that no
    /// answerer takes, because it is empty or longer than a request may be, is
    /// an error before anything is sent.
    public func askAll(_ requests: [Asked], onFrame: (Int, [UInt8]) throws -> Void) throws {
        if broken {
            throw peerError("is on a connection that an earlier answer left half read")
        }
        for asked in requests {
            if asked.request.isEmpty {
                throw invalid("a request is empty")
            }
            if asked.request.count > Scionic.maxRequestBytes {
                throw ScionicError.limitExceeded(
                    what: "a request",
                    limit: UInt64(Scionic.maxRequestBytes),
                    requested: UInt64(asked.request.count)
                )
            }
        }
        broken = true
        var answered = 0
        var flight: [UInt8] = []
        while answered < requests.count {
            // Send ahead what the connection is sure to hold, and one request
            // at the least. They go out in one write, so that a connection that
            // hands a write over whole hands them over together.
            var sent = answered
            flight.removeAll(keepingCapacity: true)
            while sent < requests.count {
                let request = requests[sent].request
                if sent > answered && flight.count + request.count + 4 > ahead {
                    break
                }
                flight.appendU32(UInt32(request.count))
                flight.append(contentsOf: request)
                sent += 1
            }
            do {
                try output.write(flight)
            } catch {
                throw streamFailure(error, "send a request")
            }
            try flush(output, "send a request")
            for place in answered..<sent {
                reading: while true {
                    switch try readNext(input, limit: requests[place].limit, into: &frame) {
                    case .frame:
                        try onFrame(place, frame)
                    case .end:
                        break reading
                    case .closed:
                        throw peerError("closed the connection inside an answer")
                    }
                }
            }
            answered = sent
        }
        broken = false
    }
}
