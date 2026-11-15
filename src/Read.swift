// Reading a tree that a store holds: finding a path, reading a file or a
// stretch of it, and writing the tree out to disk.
//
// Everything read from the store is checked again before it is used: a list
// against the hash it was asked for by, and a chunk against the hash and the
// length its file gives it. A file's bytes are handed out only when every chunk
// they need is there. Otherwise it is an error, never a shorter file.

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

/// The record of the tree with this root.
public func recordOf(_ store: any Store, _ root: Root) throws -> Record {
    guard let record = try loadRecord(store, root) else {
        throw missing("the record of", root.hash)
    }
    return record
}

/// The entries of a folder.
public func folderOf(_ store: any Store, _ folder: Target) throws -> FolderList {
    guard let list = try loadFolder(store, folder) else {
        throw missing("the list of the folder", folder.hash)
    }
    return list
}

/// The list of a file's chunks.
public func fileOf(_ store: any Store, _ file: Target) throws -> FileList {
    guard let list = try loadFile(store, file) else {
        throw missing("the list of the file", file.hash)
    }
    return list
}

/// What is at `path` in a tree: names with `/` between them, as in
/// `weights/model.safetensors`. Nothing is there when a name on the way is
/// missing, or is a file. A path that leads through more folders than a tree
/// may have is an error.
public func lookup(_ store: any Store, _ root: Root, path: String) throws -> Entry? {
    var current = try recordOf(store, root).top
    var found: Entry?
    // Split at the byte `/`, as the format reads a path: a `/` that a mark
    // joins to the next letter is still a `/`.
    for (foldersPassed, name) in path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).enumerated() {
        let name = Array(name)
        try checkName(bytes: name)
        if current.kind != .folder {
            return nil
        }
        if foldersPassed >= Scionic.maxFolderDepth {
            throw ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
        }
        guard let entry = try folderOf(store, current).get(bytes: name) else {
            return nil
        }
        current = entry.target
        found = entry
    }
    return found
}

/// Bytes written to memory: a stretch of a file, or a tree as one stream, that
/// is to be held in memory.
public final class MemorySink: ByteSink {
    /// What was written, in order.
    public var bytes: [UInt8] = []

    public init() {}

    public func write(_ more: UnsafeRawBufferPointer) throws {
        bytes.append(contentsOf: more)
    }
}

/// Writes all of a file's bytes to `sink`.
public func readFile(_ store: any Store, _ file: Target, to sink: any ByteSink) throws {
    try readRange(store, file, offset: 0, length: file.size, to: sink)
}

/// A file's bytes, in memory.
public func readFile(_ store: any Store, _ file: Target) throws -> [UInt8] {
    guard file.size <= UInt64(Int.max) else {
        throw ScionicError.sizeOverflow(field: "a file read into memory")
    }
    guard canAllocate(file.size) else {
        throw ScionicError.allocationFailed(resource: "a file read into memory", requested: file.size)
    }
    let sink = MemorySink()
    sink.bytes.reserveCapacity(Int(file.size))
    try readFile(store, file, to: sink)
    return sink.bytes
}

/// Whether `count` bytes can be had from the system now.
///
/// Swift stops the process when it cannot have the memory it asks for. A small
/// tree can stand for a file far larger than any memory, one chunk used over
/// and over, so its size is tried first, and an error is given instead.
func canAllocate(_ count: UInt64) -> Bool {
    guard count > 0 else {
        return true
    }
    guard count <= UInt64(Int.max), let probe = malloc(Int(count)) else {
        return false
    }
    free(probe)
    return true
}

/// Writes `length` bytes of a file, from byte `offset`, to `sink`.
///
/// Before the first byte goes out, every chunk of the stretch is looked for. If
/// one is missing, nothing is written. Each chunk is then checked against its
/// hash as it is written.
///
/// The file's list is read and checked on every call. For many stretches of one
/// long file, open its list once and use `readOpen`.
public func readRange(_ store: any Store, _ file: Target, offset: UInt64, length: UInt64, to sink: any ByteSink) throws {
    let list = try fileOf(store, file)
    let (end, overflow) = offset.addingReportingOverflow(length)
    guard !overflow, end <= list.size else {
        throw invalid("a stretch of bytes is outside the file")
    }
    if length == 0 {
        return
    }
    // The chunks that hold the stretch, each with the byte it starts at.
    var wanted: [(item: ChunkRef, start: UInt64)] = []
    var start: UInt64 = 0
    for item in list.items {
        if start >= end {
            break
        }
        let after = start + UInt64(item.length)
        if after > offset {
            wanted.append((item, start))
        }
        start = after
    }
    try writeStretch(store, wanted, offset, end, sink)
}

/// Writes `length` bytes of a file whose list is open, from byte `offset`, to
/// `sink`. It does what `readRange` does, and finds the chunks without a pass
/// over the list.
public func readOpen(_ store: any Store, _ file: OpenFile, offset: UInt64, length: UInt64, to sink: any ByteSink) throws {
    if length == 0 {
        guard offset <= file.list.size else {
            throw invalid("a stretch of bytes is outside the file")
        }
        return
    }
    let (first, after) = try file.chunksFor(offset: offset, length: length)
    var wanted: [(item: ChunkRef, start: UInt64)] = []
    for number in first..<after {
        guard number < UInt64(file.list.items.count), let start = file.startOf(number) else {
            throw ScionicError.invariant("an open file names a chunk it does not have")
        }
        wanted.append((file.list.items[Int(number)], start))
    }
    try writeStretch(store, wanted, offset, offset + length, sink)
}

/// Writes the bytes from `offset` up to `end` out of the chunks that hold them.
/// Each chunk comes with the byte of the file it starts at.
private func writeStretch(
    _ store: any Store,
    _ wanted: [(item: ChunkRef, start: UInt64)],
    _ offset: UInt64,
    _ end: UInt64,
    _ sink: any ByteSink
) throws {
    for (item, _) in wanted {
        guard let size = try store.size(.chunk, item.hash) else {
            throw missing("the chunk", item.hash)
        }
        guard size == UInt64(item.length) else {
            throw ScionicError.sizeMismatch(what: "a stored chunk", expected: UInt64(item.length), actual: size)
        }
    }
    for (item, start) in wanted {
        let from = Int(offset > start ? offset - start : 0)
        let to = Int(min(end, start + UInt64(item.length)) - start)
        let held = try lendChunk(store, item) { bytes in
            do {
                try sink.write(UnsafeRawBufferPointer(rebasing: bytes[from..<to]))
            } catch {
                throw streamFailure(error, "write a file's bytes")
            }
        }
        guard held else {
            throw missing("the chunk", item.hash)
        }
    }
}

/// Why this system cannot hold a name as it is, if it cannot.
///
/// A tree can hold a name that one system cannot. What is checked here is what
/// would make a name land somewhere else than it says: on another file, on a
/// device, or outside the folder.
public func unwritable(_ name: String) -> String? {
    if (try? checkName(name)) == nil {
        return "the format does not allow it"
    }
    #if os(Windows)
    return unwritableOnWindows(name)
    #else
    return nil
    #endif
}

/// Why Windows cannot hold a name as it is, if it cannot.
public func unwritableOnWindows(_ name: String) -> String? {
    let forbidden: Set<Unicode.Scalar> = ["<", ">", ":", "\"", "|", "?", "*", "\\", "/"]
    if name.unicodeScalars.contains(where: { forbidden.contains($0) || $0.value < 0x20 }) {
        return "it holds a character that Windows does not allow in a name"
    }
    if name.utf8.last == 0x2E || name.utf8.last == 0x20 {
        return "Windows drops a dot or a space at the end of a name"
    }
    // A device name is one whatever follows its first dot: `NUL.txt` is `NUL`.
    var stem = Array(name.unicodeScalars.prefix { $0 != "." })
    while stem.last == " " {
        stem.removeLast()
    }
    let upper = stem.map { scalar -> Unicode.Scalar in
        ("a"..."z").contains(scalar) ? Unicode.Scalar(scalar.value - 32)! : scalar
    }
    func numbered(_ port: String) -> Bool {
        let prefix = Array(port.unicodeScalars)
        guard upper.count == prefix.count + 1, Array(upper.prefix(prefix.count)) == prefix, let last = upper.last else {
            return false
        }
        return ("0"..."9").contains(last) || last == "\u{B9}" || last == "\u{B2}" || last == "\u{B3}"
    }
    let devices = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
    if devices.contains(where: { Array($0.unicodeScalars) == upper }) || numbered("COM") || numbered("LPT") {
        return "Windows takes it for a device"
    }
    return nil
}

private func unwritableError(_ name: String, _ reason: String) -> ScionicError {
    .unwritableName(name: String(name.prefix(80)), reason: reason)
}

extension Scionic {
    /// The most files and folders that `writeToDisk` makes unless it is told
    /// otherwise.
    public static let defaultMaxWrittenEntries: UInt64 = 1_000_000
}

/// How far writing a tree out may go.
///
/// A tree keeps each folder once, however many places the folder has in it, and
/// writing it out makes the folder at every one of those places. So a tree of a
/// few small lists can stand for more folders than any disk holds: a folder
/// with two names for one folder, a hundred deep. Both limits are held before
/// anything is written.
public struct WriteOptions: Hashable, Sendable {
    /// The most files and folders that may be made, the top one counted.
    public var maxEntries: UInt64
    /// The most bytes that may be written. A tree's record says how many it
    /// takes: the size of what is on top, with a file or a chunk that the tree
    /// uses twice counted twice.
    public var maxBytes: UInt64

    public init(maxEntries: UInt64 = Scionic.defaultMaxWrittenEntries, maxBytes: UInt64 = .max) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }
}

/// Writes a tree out to disk: its top folder as the new folder `dest`, or its
/// top file as the new file `dest`.
///
/// Writing is stricter than holding. `dest` must not exist. Before anything is
/// written, the whole tree is looked through: every list and every chunk must be
/// there, no folder may sit too deep, every name must be one that this system
/// can hold as it is, and what would be made must fit within `options`. Every
/// file and folder is then created as new. Where two names of one folder would
/// land on the same file, as `File` and `file` do on Windows and macOS, the
/// second one is refused, and so is a name that the system keeps differently
/// from how it was given. A name is never changed to make it fit: the error says
/// which name it was.
///
/// A tree holds no links, and every folder written into is one this call
/// created, so nothing is written outside `dest`. After an error, what was
/// written so far stays.
public func writeToDisk(_ store: any Store, _ root: Root, to dest: String, options: WriteOptions = WriteOptions()) throws {
    let top = try recordOf(store, root).top

    // First: find everything, count what would be made, and write nothing.
    let entries: UInt64
    switch top.kind {
    case .file:
        try requireChunks(store, fileOf(store, top))
        entries = 1
    case .folder:
        entries = try survey(store, top)
    }
    if entries > options.maxEntries {
        throw ScionicError.limitExceeded(
            what: "the files and folders that writing the tree out makes",
            limit: options.maxEntries,
            requested: entries
        )
    }
    if top.size > options.maxBytes {
        throw ScionicError.limitExceeded(what: "the bytes that writing the tree out takes", limit: options.maxBytes, requested: top.size)
    }
    if top.kind == .file {
        // The place a caller names is the caller's.
        let out: DiskFile
        do {
            out = try createFileAt(dest)
        } catch {
            throw ioError(error, "create the file", dest)
        }
        return try fillFile(store, top, out, dest)
    }

    // Then: write. From here on nothing is reached by its path. The new folder
    // is held open, and so is every folder under it while it is filled, so no
    // folder on the way can be swapped for a link.
    //
    // A folder is made with its folder's other entries, and filled when its
    // turn comes. The folders on the way down to the one that is filled stay
    // open, and no others.
    let held: Held
    do {
        held = try Held.create(dest)
    } catch {
        throw notMade(dest, error, nil)
    }
    var way: [(held: Held, inside: [(name: [UInt8], folder: Target)])] = []
    var next: (Held, Target)? = (held, top)
    while true {
        if let (held, folder) = next {
            next = nil
            way.append((held, try fillFolder(store, held, folder)))
        }
        guard let last = way.last else {
            break
        }
        if let (name, folder) = way[way.count - 1].inside.popLast() {
            do {
                next = (try last.held.openFolder(name), folder)
            } catch {
                throw reopened(joined(last.held.path, String(decoding: name, as: UTF8.self)), error)
            }
        } else {
            way.removeLast()
        }
    }
}

/// Fills a new folder that is held open: writes its files, makes the folders
/// inside it, and holds what it then lists against what it was given. Gives the
/// folders inside it, which are still to be filled.
private func fillFolder(_ store: any Store, _ held: Held, _ folder: Target) throws -> [(name: [UInt8], folder: Target)] {
    let list = try folderOf(store, folder)
    var inside: [(name: [UInt8], folder: Target)] = []
    for entry in list.entries {
        let child = joined(held.path, entry.name)
        switch entry.kind {
        case .file:
            let out: DiskFile
            do {
                out = try held.createFile(entry.nameBytes)
            } catch {
                if taken(held, entry.nameBytes, error) {
                    throw unwritableError(entry.name, "another name of its folder lands on the same place")
                }
                throw ioError(error, "create the file", child)
            }
            try fillFile(store, entry.target, out, child)
        case .folder:
            // Made now, with the names beside it. It is opened again when its
            // turn comes, so that a folder of many folders does not keep them
            // all open.
            do {
                _ = try held.createFolder(entry.nameBytes)
            } catch {
                throw notMade(child, error, (held, entry))
            }
            inside.append((entry.nameBytes, entry.target))
        }
    }
    // The folder must now hold exactly the names it was given.
    try confirmNames(held, list)
    return inside
}

/// Looks through a whole tree before it is written out, each folder once,
/// however many places it has. Every list and every chunk must be there, every
/// name must be one this system can hold, and no folder may sit too deep. Gives
/// how many files and folders writing the tree makes, the top one counted, and
/// a folder with several places counted at each.
private func survey(_ store: any Store, _ top: Target) throws -> UInt64 {
    let tooDeep = ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
    // For each folder that is done: how many files and folders are below it,
    // and how many folders deep it goes, itself counted.
    var done: [Hash: (below: UInt64, deep: Int)] = [:]
    var checkedFiles = Set<Hash>()
    // The folders on the way down: each with its list, and with the place of
    // the entry that is looked at next.
    let first = try folderOf(store, top)
    try checkNames(first)
    var path: [(hash: Hash, list: FolderList, next: Int)] = [(top.hash, first, 0)]
    while let last = path.last {
        let place = last.next
        path[path.count - 1].next += 1
        if place < last.list.entries.count {
            let entry = last.list.entries[place]
            switch entry.kind {
            case .file:
                if checkedFiles.insert(entry.hash).inserted {
                    try requireChunks(store, fileOf(store, entry.target))
                }
            case .folder:
                if done[entry.hash] != nil {
                    continue
                }
                if path.count >= Scionic.maxFolderDepth {
                    throw tooDeep
                }
                let inside = try folderOf(store, entry.target)
                try checkNames(inside)
                path.append((entry.hash, inside, 0))
            }
        } else {
            // Every entry is looked at, and every folder inside is done.
            path.removeLast()
            var below: UInt64 = 0
            var deep = 1
            for entry in last.list.entries {
                below = below == .max ? below : below + 1
                if entry.kind == .folder {
                    guard let (inside, depth) = done[entry.hash] else {
                        throw ScionicError.invariant("a folder is counted before the folders inside it")
                    }
                    let (sum, overflow) = below.addingReportingOverflow(inside)
                    below = overflow ? .max : sum
                    deep = max(deep, depth + 1)
                }
            }
            if deep > Scionic.maxFolderDepth {
                throw tooDeep
            }
            done[last.hash] = (below, deep)
        }
    }
    guard let (below, _) = done[top.hash] else {
        throw ScionicError.invariant("the top folder is not counted")
    }
    return below == .max ? below : below + 1
}

/// Every name of a folder has to be one that this system can hold as it is.
private func checkNames(_ folder: FolderList) throws {
    for entry in folder.entries {
        if let reason = unwritable(entry.name) {
            throw unwritableError(entry.name, reason)
        }
    }
}

/// Every chunk of a file has to be held, with the length its list gives it.
private func requireChunks(_ store: any Store, _ list: FileList) throws {
    for item in list.items {
        guard let size = try store.size(.chunk, item.hash) else {
            throw missing("the chunk", item.hash)
        }
        guard size == UInt64(item.length) else {
            throw ScionicError.sizeMismatch(what: "a stored chunk", expected: UInt64(item.length), actual: size)
        }
    }
}

/// Whether something is at `name` in `held`, be it a file, a folder or a link.
/// Systems do not agree on the error they give for making a thing where another
/// one is, so the place is looked at.
private func taken(_ held: Held, _ name: [UInt8], _ error: any Error) -> Bool {
    (error as? SystemFailure)?.kind == .alreadyExists || held.has(name)
}

/// Why a folder was not made at `path`.
private func notMade(_ path: String, _ error: any Error, _ within: (held: Held, entry: Entry)?) -> any Error {
    if let within {
        if taken(within.held, within.entry.nameBytes, error) {
            return unwritableError(within.entry.name, "something is there already under that name")
        }
    } else if let name = lastName(path), (error as? SystemFailure)?.kind == .alreadyExists || existsAt(path) {
        return unwritableError(name, "something is there already under that name")
    }
    return ioError(error, "create the folder", path)
}

/// The last name in a path, if it ends in one: not in `..`, nor in a drive.
private func lastName(_ path: String) -> String? {
    #if os(Windows)
    let isSeparator: (Unicode.Scalar) -> Bool = { $0 == "/" || $0 == "\\" }
    #else
    let isSeparator: (Unicode.Scalar) -> Bool = { $0 == "/" }
    #endif
    let names = path.unicodeScalars.split(whereSeparator: isSeparator).map { String(String.UnicodeScalarView($0)) }
    guard let last = names.last(where: { $0 != "." }), last != ".." else {
        return nil
    }
    #if os(Windows)
    if last.hasSuffix(":") {
        return nil
    }
    #endif
    return last
}

/// A folder that was made has to be that folder still when its turn comes.
private func reopened(_ path: String, _ refused: Refused) -> ScionicError {
    switch refused {
    case let .failure(failure):
        return .io(operation: "open the folder", path: path, failure: failure)
    case .link, .other:
        return invalid("a folder that was written was swapped for something else before it was filled")
    }
}

/// A file that was just made, being filled. A failure to write names it.
private final class FileOut: ByteSink {
    let file: DiskFile
    let path: String

    init(_ file: DiskFile, _ path: String) {
        self.file = file
        self.path = path
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        do {
            try file.write(bytes)
        } catch {
            throw ioError(error, "write", path)
        }
    }
}

/// Writes a file's bytes into a file that was just made. `path` is for
/// messages.
private func fillFile(_ store: any Store, _ file: Target, _ out: DiskFile, _ path: String) throws {
    try readFile(store, file, to: FileOut(out, path))
}

/// A folder that was written must list exactly the names it was given, byte for
/// byte. Where the system changed a name, the tree was not written as it is.
private func confirmNames(_ held: Held, _ folder: FolderList) throws {
    let listed: [(name: [UInt8]?, raw: String, found: Found)]
    do {
        listed = try held.list()
    } catch {
        throw ioError(error, "list", held.path)
    }
    let written = Set(listed.compactMap(\.name))
    for entry in folder.entries where !written.contains(entry.nameBytes) {
        throw unwritableError(entry.name, "this system keeps it under another name")
    }
    if listed.count != folder.entries.count {
        throw invalid("a folder that was written holds a name it was not given")
    }
}
