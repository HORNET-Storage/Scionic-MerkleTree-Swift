// Building a tree: from a folder or a file on disk, or part by part.

import Dispatch
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// How much of a file a builder holds at a time when it works alone: two
/// chunks of the longest kind, one in each of its two windows.
private let roomAlone = 2 * FastCDC.maxSize

/// How much of a file a builder holds at a time when other threads help it,
/// in its two windows: enough chunks to give each of them some.
private let roomWithHelp = 8 * FastCDC.maxSize

/// The least of a file that is worth a thread of its own, when several threads
/// look through it for where its chunks may end.
private let lookedThroughByEach = 4 << 20

/// The least bytes of chunks that are worth a helper of their own, while the
/// thread that reads a file reads on.
private let keptByEach = 1 << 20

/// The most chunks of a fixed size that a window holds.
private let fixedChunksInAWindow = 1024

/// How many of a file's windows in a row must find its chunks still being kept
/// once the next window is read, while as many helpers are free as the window
/// could use, before its windows grow to what a builder with help holds.
/// Helpers are free for a moment while other files are between windows, and
/// that is not worth the memory.
let windowsBehindToGrow = 3

/// What a window holds when it starts on its first file. A window grows only as
/// a file turns out to be longer, so a small file never costs a large one.
private let windowStart = 64 * 1024

/// How many folders' files may wait for the threads that chunk. A folder is
/// kept open while it has files that are not chunked yet, so this bounds how
/// many folders are open at a time.
private let foldersAhead = 16

/// A value that is handed to other threads by a caller that keeps it alive and
/// unchanged until they are done with it.
final class Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// The threads that are free to help with a long file.
///
/// Where one chunk ends decides where the next begins, so a file is chunked in
/// order, on the thread that asks for it. A long stretch of a file is first
/// looked through by the helpers that are free, each in a part of its own, for
/// every place where a chunk may end, and is then chunked from those places
/// alone. Hashing and keeping the chunks is the greater part of the work and
/// needs no order, so it is shared out among that thread and the helpers that
/// are free: for a file that is read, while that thread reads on.
final class Helpers: @unchecked Sendable {
    private let lock = Lock()
    private var free: Int

    init(free: Int) {
        self.free = max(free, 0)
    }

    /// The helpers of a builder that may use `threads` threads, its own
    /// counted. Zero is one thread for each core.
    static func forThreads(_ threads: Int) -> Helpers {
        Helpers(free: (threads == 0 ? processorCount() : threads) - 1)
    }

    /// How many helpers are free.
    var available: Int {
        lock.withLock { free }
    }

    var any: Bool {
        available > 0
    }

    /// Takes up to `most` helpers, and says how many it got.
    func take(_ most: Int) -> Int {
        lock.withLock {
            let taken = max(0, min(free, most))
            free -= taken
            return taken
        }
    }

    func give(_ count: Int) {
        lock.withLock { free += count }
    }
}



/// A failure of the system at `path`, as an error of this library.
func ioError(_ error: any Error, _ operation: String, _ path: String) -> any Error {
    if let failure = error as? SystemFailure {
        return ScionicError.io(operation: operation, path: path, failure: failure)
    }
    return error
}

/// Builds a tree part by part: files from their bytes, folders from their
/// entries, and at the end the record.
///
/// Everything goes into the store as it is made. A chunk, a file or a folder
/// that the store holds already is not written again.
public final class Builder {
    let store: any Store
    /// How this builder chunks files.
    public let chunking: Chunking
    /// What the builder holds of a file that it reads: while the chunks of one
    /// window are hashed and kept, the file is read on into the other.
    private var windows = (current: Window(), next: Window())
    private let helpers: Helpers

    /// A builder that works on one file with `threads` threads: 1 is the
    /// calling thread alone, and zero is one thread for each core. They find
    /// where its chunks end, and hash and keep them; for a file that is read,
    /// while the calling thread reads on. With help, a builder holds up to
    /// 64 MiB of a long file that it reads at a time; alone it holds up to
    /// 16 MiB. When the tree is finished, they look in the store for the chunks
    /// of its long lists.
    public init(store: any Store, chunking: Chunking = .fastCDCv1, threads: Int = 0) {
        self.store = store
        self.chunking = chunking
        self.helpers = Helpers.forThreads(threads)
    }

    init(store: any Store, chunking: Chunking, helpers: Helpers) {
        self.store = store
        self.chunking = chunking
        self.helpers = helpers
    }

    /// Splits everything `source` gives into chunks, keeps the chunks and the
    /// file's list, and says what the file is. The file is never held in
    /// memory whole: only a part of it at a time, as `init` says.
    public func file(from source: any ByteSource) throws -> Target {
        try file { buffer in
            do {
                return try readSome(source, buffer)
            } catch {
                throw streamFailure(error, "read a file's bytes")
            }
        }
    }

    /// The file with these bytes. They are chunked where they lie, and nothing
    /// is copied on the way to the store.
    public func file(bytes: [UInt8]) throws -> Target {
        try bytes.withUnsafeBytes { all in
            let chunks = settled(chunking, helpers, all, ended: true)
            var items: [ChunkRef] = []
            items.reserveCapacity(chunks.count)
            try keepChunks(store, helpers, chunks, &items)
            return try keepList(items)
        }
    }

    /// The file at `path` on disk, as the caller names it.
    public func file(at path: String) throws -> Target {
        let opened: DiskFile
        do {
            opened = try openFileAt(path)
        } catch {
            throw ioError(error, "open", path)
        }
        return try file { buffer in
            do {
                return try readSome(opened, buffer)
            } catch {
                throw ioError(error, "read", path)
            }
        }
    }

    /// Chunks, hashes and keeps a file that `read` reads, one window at a time.
    /// While the chunks of one window are hashed and kept, what is left of it
    /// goes to the start of the other, and the file is read on into that one.
    ///
    /// A file that starts while no helper is free is read in short windows.
    /// They grow once keeping its chunks is what holds the file up while
    /// helpers are free: a store that writes each chunk to a disk keeps it more
    /// slowly than the file is read, and a longer window gives the free helpers
    /// a share.
    func file(read: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> Target {
        let store = self.store
        let chunking = self.chunking
        let helpers = self.helpers
        var room = windowRoom(chunking, help: helpers.any)
        var behindInARow = 0
        var items: [ChunkRef] = []
        var (filled, ended) = try fill(windows.current, 0, room, read)
        while filled > 0 {
            let (current, next) = windows
            let chunks = settled(chunking, helpers, UnsafeRawBufferPointer(rebasing: current.memory[..<filled]), ended: ended)
            if chunks.isEmpty {
                throw ScionicError.invariant("a full window settled no chunk")
            }
            let settledTo = chunks.reduce(0) { $0 + $1.count }
            let tail = UnsafeRawBufferPointer(rebasing: current.memory[settledTo..<filled])
            // Once the file has ended there is nothing to read meanwhile. A window
            // takes no more helpers than it has chunks, and leaves the others to
            // the files beside it.
            let most = ended ? chunks.count / 2 : min((settledTo + keptByEach - 1) / keptByEach, chunks.count)
            let refilled = try keepChunksWhile(store, helpers, most, chunks, &items) { behind in
                Result<(Int, Bool), any Error> {
                    carry(tail, into: next, room)
                    if ended {
                        return (tail.count, true)
                    }
                    let refilled = try fill(next, tail.count, room, read)
                    if behind() && helpers.available >= most {
                        behindInARow += 1
                        if behindInARow >= windowsBehindToGrow {
                            room = windowRoom(chunking, help: true)
                        }
                    } else {
                        behindInARow = 0
                    }
                    return refilled
                }
            }
            (filled, ended) = try refilled.get()
            windows = (current: next, next: current)
        }
        return try keepList(items)
    }

    /// Keeps the list of a file whose chunks are kept, and says what the file
    /// is.
    private func keepList(_ items: [ChunkRef]) throws -> Target {
        let list = try FileList(items: items)
        if try !store.has(.fileList, list.hash) {
            try store.put(.fileList, list.hash, list.encode())
        }
        return list.target
    }

    /// Keeps the folder with these entries, and says what it is. The entries
    /// may come in any order. Two entries with one name are an error.
    public func folder(_ entries: [Entry]) throws -> Target {
        let list = try FolderList(entries: entries.sorted { bytesLess($0.nameBytes, $1.nameBytes) })
        if try !store.has(.folderList, list.hash) {
            try store.put(.folderList, list.hash, list.encode())
        }
        return list.target
    }

    /// Writes the record of the tree that has `top` on top, and gives the
    /// tree's root. The store must hold every list under `top`.
    ///
    /// The whole tree is checked before its record is kept: its sizes, how its
    /// files are chunked, and how deep its folders sit. The checks are the ones
    /// a tree goes through when it is taken in, and the totals in the record
    /// are what those checks counted.
    public func finish(top: Target, extra: ExtraData = ExtraData()) throws -> Root {
        // The tree is measured with this builder's threads: the helpers that are
        // free look in the store for the chunks of a long list.
        let helping = helpers.take(Int.max)
        defer { helpers.give(helping) }
        let totals = try Intake.measure(store, top: top, chunking: chunking, threads: helping + 1)
        let record = try Record(top: top, totals: totals, chunking: chunking, extra: extra)
        let bytes = record.encode()
        let root = Root.of(record: bytes)
        try store.put(.record, root.hash, bytes)
        return root
    }
}

/// Hashes and keeps one chunk, and says what it is. A chunk that the store
/// holds already is not written again.
private func keepChunk(_ store: any Store, _ chunk: UnsafeRawBufferPointer) throws -> ChunkRef {
    let item = try ChunkRef.of(chunk)
    if try !store.has(.chunk, item.hash) {
        try store.put(.chunk, item.hash, chunk)
    }
    return item
}

/// Hashes and keeps chunks that follow one another in a file, and adds what
/// they are to `items`, in their order. Helpers that are free take a share.
private func keepChunks(
    _ store: any Store,
    _ helpers: Helpers,
    _ chunks: [UnsafeRawBufferPointer],
    _ items: inout [ChunkRef]
) throws {
    // A helper is worth starting only for a few chunks of its own.
    try keepChunksWhile(store, helpers, chunks.count / 2, chunks, &items) { _ in }
}

/// Hashes and keeps chunks as `keepChunks` does, with up to `most` helpers,
/// while this thread does `meanwhile`; then this thread takes a share too.
/// `meanwhile` can ask whether helpers are still keeping the chunks. Gives
/// what `meanwhile` gave, once the chunks are kept. A chunk that could not be
/// kept is the error, whatever `meanwhile` gave.
private func keepChunksWhile<T>(
    _ store: any Store,
    _ helpers: Helpers,
    _ most: Int,
    _ chunks: [UnsafeRawBufferPointer],
    _ items: inout [ChunkRef],
    meanwhile: (_ behind: () -> Bool) -> T
) throws -> T {
    let helping = helpers.take(most)
    if helping == 0 {
        // With no helper, nothing is kept before `meanwhile` is done, and that
        // says nothing of how fast the store keeps.
        let done = meanwhile { false }
        for chunk in chunks {
            items.append(try keepChunk(store, chunk))
        }
        return done
    }
    defer { helpers.give(helping) }
    let lent = Unchecked(chunks)
    let dealer = Dealer(count: chunks.count)
    let kept = Shared([ChunkRef?](repeating: nil, count: chunks.count))
    let finished = Shared(0)
    let work: @Sendable () -> Void = {
        while let index = dealer.take() {
            do {
                let item = try keepChunk(store, lent.value[index])
                kept.with { $0[index] = item }
            } catch {
                dealer.fail(error)
            }
            finished.with { $0 += 1 }
        }
    }
    let group = DispatchGroup()
    for _ in 0..<helping {
        DispatchQueue.global().async(group: group, execute: work)
    }
    let done = meanwhile { finished.with { $0 } < chunks.count }
    work()
    group.wait()
    try dealer.check()
    for item in kept.with({ $0 }) {
        guard let item else {
            throw ScionicError.invariant("a chunk was left out of a file")
        }
        items.append(item)
    }
    return done
}

/// The chunks of `data`, the start of what is left of a file, that are
/// settled: all of them once the file has ended. Helpers that are free look
/// through a long stretch for where its chunks may end.
private func settled(
    _ chunking: Chunking,
    _ helpers: Helpers,
    _ data: UnsafeRawBufferPointer,
    ended: Bool
) -> [UnsafeRawBufferPointer] {
    var lengths: [Int] = []
    if let size = chunking.fixedSize.map(Int.init) {
        var left = data.count
        while left > 0 && (ended || left >= size) {
            let length = min(size, left)
            lengths.append(length)
            left -= length
        }
    } else {
        let helping = helpers.take(data.count / lookedThroughByEach - 1)
        lengths = fastCDCLengths(data, ended: ended, threads: helping + 1)
        helpers.give(helping)
    }
    var chunks: [UnsafeRawBufferPointer] = []
    chunks.reserveCapacity(lengths.count)
    var start = 0
    for length in lengths {
        chunks.append(UnsafeRawBufferPointer(rebasing: data[start..<(start + length)]))
        start += length
    }
    return chunks
}

/// The most bytes one of a builder's two windows holds: half of what the
/// builder may hold, and never less than one chunk of the longest kind.
private func windowRoom(_ chunking: Chunking, help: Bool) -> Int {
    let room = help ? roomWithHelp : roomAlone
    guard let size = chunking.fixedSize.map(Int.init) else {
        return max(room / 2, FastCDC.maxSize)
    }
    let (most, overflow) = size.multipliedReportingOverflow(by: fixedChunksInAWindow)
    return max(min(room / 2, overflow ? Int.max : most), size)
}

/// One of the two windows a builder holds a file that it reads in.
private final class Window {
    private(set) var memory = UnsafeMutableRawBufferPointer(start: nil, count: 0)

    deinit {
        memory.deallocate()
    }

    /// Makes the window at least `least` bytes long: twice as long as it was,
    /// and no longer than `room` unless `least` is longer. What it held stays.
    func grow(least: Int, room: Int) {
        let length = max(min(max(memory.count * 2, windowStart), room), least)
        guard length > memory.count else {
            return
        }
        let larger = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 16)
        if memory.count > 0 {
            larger.copyMemory(from: UnsafeRawBufferPointer(memory))
        }
        memory.deallocate()
        memory = larger
    }
}

/// Reads into `window` from `filled` on, until it holds `room` bytes or the file
/// has ended. Gives how many bytes it holds, and whether the file has ended.
private func fill(
    _ window: Window,
    _ filled: Int,
    _ room: Int,
    _ read: (UnsafeMutableRawBufferPointer) throws -> Int
) throws -> (Int, Bool) {
    var filled = filled
    while filled < room {
        if filled == window.memory.count {
            window.grow(least: filled + 1, room: room)
        }
        let end = min(window.memory.count, room)
        let count = try read(UnsafeMutableRawBufferPointer(rebasing: window.memory[filled..<end]))
        guard count >= 0, count <= end - filled else {
            throw ScionicError.invariant("a reader gave more bytes than it was asked for")
        }
        if count == 0 {
            return (filled, true)
        }
        filled += count
    }
    return (filled, false)
}

/// Puts `tail`, what is left of one window, at the start of the other.
private func carry(_ tail: UnsafeRawBufferPointer, into window: Window, _ room: Int) {
    if window.memory.count < tail.count {
        window.grow(least: tail.count, room: room)
    }
    if let from = tail.baseAddress, let to = window.memory.baseAddress {
        to.copyMemory(from: from, byteCount: tail.count)
    }
}

/// What a builder does with a link or a special file that it finds in a folder.
/// Neither is stored in a tree, and a link is never followed: it could lead out
/// of the folder that is being built.
public enum Links: Hashable, Sendable {
    /// Stop, and say which one it was.
    case refuse
    /// Leave it out of the tree.
    case skip
}

/// How a tree is built from disk.
public struct BuildOptions: Sendable {
    /// How files are chunked. Every tree outside a test should be chunked by
    /// content, which is the default.
    public var chunking: Chunking
    /// Extra data for the tree's record.
    public var extra: ExtraData
    /// Writes the time of building into the record. Two builds of the same
    /// folder then have different roots.
    public var timestamp: Bool
    /// How many threads build the tree. Zero is one for each core. Files are
    /// chunked several at once, and a thread that has no file of its own helps
    /// to hash the chunks of a long one.
    public var workers: Int
    public var links: Links

    public init(
        chunking: Chunking = .fastCDCv1,
        extra: ExtraData = ExtraData(),
        timestamp: Bool = false,
        workers: Int = 0,
        links: Links = .refuse
    ) {
        self.chunking = chunking
        self.extra = extra
        self.timestamp = timestamp
        self.workers = workers
        self.links = links
    }
}

/// Builds the tree of the folder or the file at `path` into `store`, and gives
/// its root.
///
/// A folder's own name is not part of its tree, so the same folder gives the
/// same root wherever it is and whatever it is called. Entries have no extra
/// data unless `entryExtra` gives some: it is asked with each entry's path on
/// disk, its name, and whether it is a file or a folder.
public func build(
    _ store: any Store,
    path: String,
    options: BuildOptions = BuildOptions(),
    entryExtra: ((String, String, Kind) throws -> ExtraData)? = nil
) throws -> Root {
    var extra = options.extra
    if options.timestamp {
        try extra.insert(Scionic.timestampKey, text: timestamp(secondsSinceEpoch()))
    }
    let isFolder: Bool
    do {
        isFolder = try isFolderAt(path)
    } catch {
        throw ioError(error, "look at", path)
    }
    let builder = Builder(store: store, chunking: options.chunking, threads: options.workers)
    if !isFolder {
        return try builder.finish(top: builder.file(at: path), extra: extra)
    }

    // From here on nothing is reached by its path: the folder is held open, and
    // so is every folder under it while it is read.
    let top: Held
    do {
        top = try Held.open(path)
    } catch {
        throw ioError(error, "open", path)
    }
    let (folders, fileTargets) = try walkAndChunk(store, options.chunking, top, options.links, options.workers)
    // A folder is found after the folder it is in, so going backwards every
    // folder is made after the folders inside it.
    var folderTargets = [Target?](repeating: nil, count: folders.count)
    for index in folders.indices.reversed() {
        var entries: [Entry] = []
        entries.reserveCapacity(folders[index].children.count)
        for child in folders[index].children {
            let target: Target
            switch child.kind {
            case .file:
                guard child.index < fileTargets.count else {
                    throw ScionicError.invariant("a file was left out of the build")
                }
                target = fileTargets[child.index]
            case .folder:
                guard let made = folderTargets[child.index] else {
                    throw ScionicError.invariant("a folder was made before a folder inside it")
                }
                target = made
            }
            var entryData = ExtraData()
            if let entryExtra {
                // A file's path is put together here, for the caller to see, and
                // only when there is a caller to see it. No file is opened by it.
                let childPath = child.kind == .file
                    ? joined(folders[index].path, String(decoding: child.name, as: UTF8.self))
                    : folders[child.index].path
                entryData = try entryExtra(childPath, String(decoding: child.name, as: UTF8.self), child.kind)
            }
            entries.append(try Entry(nameBytes: child.name, target: target, extra: entryData))
        }
        folderTargets[index] = try builder.folder(entries)
    }
    guard let made = folderTargets.first, let made else {
        throw ScionicError.invariant("the top folder was not made")
    }
    return try builder.finish(top: made, extra: extra)
}

private struct Folder {
    var path: String
    var children: [Child]
}

private struct Child {
    let name: [UInt8]
    let kind: Kind
    /// The child's place among the folders, or among the files.
    let index: Int
}

/// The files that the walk found in one folder, for the threads to chunk. The
/// folder is held open, and each file is opened from it by its name.
private final class Batch: @unchecked Sendable {
    let folder: Held
    /// Each file's place among the files, and its name in the folder.
    let files: [(index: Int, name: [UInt8])]
    /// How many of the files are taken. Changed under the lock of `Waiting`.
    var taken = 0

    init(folder: Held, files: [(index: Int, name: [UInt8])]) {
        self.folder = folder
        self.files = files
    }
}

/// What a thread gives when it stopped because the build had failed somewhere
/// else. The error that the caller is given is that failure's.
private let stoppedDetail = "the build was stopped"

private func isStopped(_ error: any Error) -> Bool {
    if case let ScionicError.invariant(detail) = error {
        return detail == stoppedDetail
    }
    return false
}

/// What was there when a folder was read has to be there still when it is
/// opened. If a link took its place meanwhile, the link is not followed.
private func changed(_ path: String, _ refused: Refused) -> ScionicError {
    switch refused {
    case let .failure(failure):
        return .io(operation: "open", path: path, failure: failure)
    case .link:
        return .unsupportedEntry(path: path, what: "a link now, where a file or a folder was when the build began")
    case .other:
        return .unsupportedEntry(path: path, what: "something else now than it was when the build began")
    }
}

/// Chunks and keeps the file `name` of a folder that is held open. The file is
/// opened from the folder itself. Once the build has failed elsewhere, the file
/// is given up, however much of it is left.
private func chunkFileIn(_ builder: Builder, _ folder: Held, _ name: [UInt8], _ waiting: Waiting?) throws -> Target {
    // The path is for messages, and is put together only for one.
    let path = { joined(folder.path, String(decoding: name, as: UTF8.self)) }
    let file: DiskFile
    do {
        file = try folder.openFile(name)
    } catch {
        throw changed(path(), error)
    }
    return try builder.file { buffer in
        if let waiting, waiting.hasFailed {
            throw ScionicError.invariant(stoppedDetail)
        }
        do {
            return try readSome(file, buffer)
        } catch {
            throw ioError(error, "read", path())
        }
    }
}

/// What a walk through a folder has found so far.
private struct Walk {
    let links: Links
    var folders: [Folder]
    /// How many files were found.
    var files = 0
    /// Takes the files of each folder, once the folder is read.
    let onFiles: (Batch) throws -> Void

    /// Reads one folder, which is `depth` folders down from the top, the top
    /// counted. Notes what is in it, hands its files on, and gives the folders
    /// inside it, each with its place among the folders.
    mutating func read(_ held: Held, _ index: Int, _ depth: Int) throws -> [(name: [UInt8], index: Int)] {
        let folderPath = held.path
        let listed: [(name: [UInt8]?, raw: String, found: Found)]
        do {
            listed = try held.list()
        } catch {
            throw ioError(error, "list", folderPath)
        }
        var children: [Child] = []
        children.reserveCapacity(listed.count)
        var inside: [(name: [UInt8], index: Int)] = []
        var batch: [(index: Int, name: [UInt8])] = []
        for (bytes, raw, found) in listed {
            guard let name = bytes, let text = utf8Text(name) else {
                throw ScionicError.nonUTF8FileName(path: joined(folderPath, raw))
            }
            try checkName(bytes: name)
            switch found {
            case .folder:
                if depth >= Scionic.maxFolderDepth {
                    throw ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
                }
                let below = folders.count
                children.append(Child(name: name, kind: .folder, index: below))
                folders.append(Folder(path: joined(folderPath, text), children: []))
                inside.append((name, below))
            case .file:
                children.append(Child(name: name, kind: .file, index: files))
                batch.append((files, name))
                files += 1
            case .link, .other:
                if links == .refuse {
                    throw ScionicError.unsupportedEntry(path: joined(folderPath, text), what: found == .link ? "a link" : "a special file")
                }
            }
        }
        children.sort { bytesLess($0.name, $1.name) }
        folders[index].children = children
        if !batch.isEmpty {
            try onFiles(Batch(folder: held, files: batch))
        }
        return inside
    }
}

/// Finds every folder and every file under `top`, and hands the files of each
/// folder to `onFiles` once the folder is read. A link is never followed. Gives
/// the folders, and how many files there are.
///
/// A folder is opened from the folder it is in, which is held open, and is held
/// open itself while it is read. So no folder on the way to a file can be
/// swapped for a link between the reading of a folder and the opening of what
/// is in it.
private func walk(_ top: Held, _ links: Links, _ onFiles: @escaping (Batch) throws -> Void) throws -> (folders: [Folder], files: Int) {
    var walk = Walk(links: links, folders: [Folder(path: top.path, children: [])], onFiles: onFiles)
    // The folders on the way down to the one that is read, each held open, with
    // the folders inside it that are still to be read.
    var way: [(held: Held, inside: [(name: [UInt8], index: Int)])] = []
    var next: (Held, Int)? = (top, 0)
    while true {
        if let (held, index) = next {
            next = nil
            let inside = try walk.read(held, index, way.count + 1)
            way.append((held, inside))
        }
        guard let last = way.last else {
            break
        }
        if let (name, index) = way[way.count - 1].inside.popLast() {
            do {
                next = (try last.held.openFolder(name), index)
            } catch {
                throw changed(walk.folders[index].path, error)
            }
        } else {
            way.removeLast()
        }
    }
    return (walk.folders, walk.files)
}

/// The folders whose files wait for the threads that chunk, between the thread
/// that walks and those threads.
///
/// Nobody waits here for a thread that is gone. A file that cannot be chunked
/// and a walk that fails each set `failed`, and wake whoever waits.
private final class Waiting: @unchecked Sendable {
    private let lock = Lock()
    private var batches: [Batch] = []
    private var first = 0
    private var failed = false
    /// One signal for each file that is added, and one for each thread when
    /// the walk is over or the build has failed.
    private let more = DispatchSemaphore(value: 0)
    /// One signal for each folder that may still be added. It starts at none,
    /// and is given its folders in `init`: the system ends the whole program
    /// when a semaphore is let go of with fewer signals than it started with,
    /// and a build that fails lets go of it with folders still waiting.
    private let room = DispatchSemaphore(value: 0)
    private let threads: Int

    init(threads: Int) {
        self.threads = threads
        for _ in 0..<foldersAhead {
            room.signal()
        }
    }

    var hasFailed: Bool {
        lock.withLock { failed }
    }

    /// For the walk: adds a folder's files, once there is room for them.
    func add(_ batch: Batch) throws {
        room.wait()
        try lock.withLock {
            if failed {
                throw ScionicError.invariant(stoppedDetail)
            }
            batches.append(batch)
        }
        for _ in batch.files {
            more.signal()
        }
    }

    /// For a thread that chunks: a file to chunk, and the folder it is in. Nil
    /// when the walk is over and every file is taken, or when the build has
    /// failed.
    func next() -> (Batch, (index: Int, name: [UInt8]))? {
        more.wait()
        return lock.withLock {
            if failed || first == batches.count {
                return nil
            }
            let batch = batches[first]
            let file = batch.files[batch.taken]
            batch.taken += 1
            if batch.taken == batch.files.count {
                // Every file of this folder is taken: the walk may go on.
                first += 1
                if first == batches.count {
                    batches.removeAll(keepingCapacity: true)
                    first = 0
                }
                room.signal()
            }
            return (batch, file)
        }
    }

    /// Nothing more is to be chunked. The folders whose files wait are let go
    /// now: a folder is held open only while a file of it is chunked.
    func fail() {
        lock.withLock {
            failed = true
            batches.removeAll()
            first = 0
        }
        for _ in 0..<threads {
            more.signal()
        }
        room.signal()
    }

    /// The walk is over.
    func end() {
        for _ in 0..<threads {
            more.signal()
        }
    }
}

/// Finds every folder and every file under `top`, and chunks and keeps the
/// files while they are found, several at once. Gives the folders, and what
/// each file is.
private func walkAndChunk(
    _ store: any Store,
    _ chunking: Chunking,
    _ top: Held,
    _ links: Links,
    _ threads: Int
) throws -> (folders: [Folder], files: [Target]) {
    let threads = threads == 0 ? processorCount() : threads
    // A thread that has no file left gives itself up to help with the long
    // files that are still being chunked.
    let helpers = Helpers(free: 0)
    if threads <= 1 {
        // One thread walks and chunks in turn.
        let builder = Builder(store: store, chunking: chunking, helpers: helpers)
        var targets: [Target] = []
        let found = try walk(top, links) { batch in
            for (index, name) in batch.files {
                guard index == targets.count else {
                    throw ScionicError.invariant("a file was chunked out of its turn")
                }
                targets.append(try chunkFileIn(builder, batch.folder, name, nil))
            }
        }
        return (found.folders, targets)
    }
    let waiting = Waiting(threads: threads)
    let done = Shared<[(index: Int, target: Target)]>([])
    let errors = Shared<[any Error]>([])
    let group = DispatchGroup()
    for number in 0..<threads {
        // A queue of its own runs on a thread of its own, so that no thread
        // waits for a file while another waits for a thread.
        DispatchQueue(label: "scionic.build.\(number)").async(group: group) {
            let builder = Builder(store: store, chunking: chunking, helpers: helpers)
            while let (batch, file) = waiting.next() {
                do {
                    let target = try chunkFileIn(builder, batch.folder, file.name, waiting)
                    done.with { $0.append((file.index, target)) }
                } catch {
                    errors.with { $0.append(error) }
                    waiting.fail()
                }
            }
            helpers.give(1)
        }
    }
    var walked: Result<(folders: [Folder], files: Int), any Error>
    do {
        walked = .success(try walk(top, links) { try waiting.add($0) })
    } catch {
        walked = .failure(error)
        // A walk that failed stops the chunking too: a thread gives up the file
        // it is on, however long that file is.
        waiting.fail()
    }
    // With the walk over, the threads run out of files and end.
    waiting.end()
    group.wait()
    // The failure that came first in its thread is the one to tell. A thread
    // that only stopped for another's failure has nothing to tell.
    let failures = errors.with { $0 }
    if let real = failures.first(where: { !isStopped($0) }) {
        throw real
    }
    let (folders, count) = try walked.get()
    if let stopped = failures.first {
        throw stopped
    }
    var targets = [Target?](repeating: nil, count: count)
    for (index, target) in done.with({ $0 }) {
        targets[index] = target
    }
    return (folders, try targets.map { target in
        guard let target else {
            throw ScionicError.invariant("a file was left out of the build")
        }
        return target
    })
}

/// The seconds since 1970 began, in UTC.
func secondsSinceEpoch() -> Int64 {
    #if os(Windows)
    var now = FILETIME()
    GetSystemTimeAsFileTime(&now)
    let ticks = UInt64(now.dwHighDateTime) << 32 | UInt64(now.dwLowDateTime)
    // A tick is a tenth of a millionth of a second, from 1601.
    return Int64(ticks / 10_000_000) - 11_644_473_600
    #else
    return Int64(time(nil))
    #endif
}

/// The time as text: `2026-11-12T08:30:00Z`, in UTC, to the second.
func timestamp(_ seconds: Int64) -> String {
    func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
    let days = floorDivide(seconds, 86_400)
    let secondsOfDay = seconds - days * 86_400
    let shiftedDays = days + 719_468
    let era = floorDivide(shiftedDays, 146_097)
    let dayOfEra = shiftedDays - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    var year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPrime = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
    let month = monthPrime + (monthPrime < 10 ? 3 : -9)
    if month <= 2 {
        year += 1
    }
    func two(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
    let hour = secondsOfDay / 3_600
    let minute = secondsOfDay % 3_600 / 60
    let second = secondsOfDay % 60
    let yearText = String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year)
    return "\(yearText)-\(two(month))-\(two(day))T\(two(hour)):\(two(minute)):\(two(second))Z"
}
