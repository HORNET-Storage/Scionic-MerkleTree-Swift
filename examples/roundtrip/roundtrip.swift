// Roundtrip takes a tree its whole way round, with a store on disk.
//
// It builds a tree from a folder, checks it, fetches it into a second store
// as a receiver would, reads stretches of its largest file without the rest,
// writes the tree out again, and holds the copy to the same root. It prints
// how long each step took.
//
//     swift run -c release roundtrip <folder> <work-dir>
//
// <work-dir> must not exist. The stores and the copy are made in it.
//
// The store here keeps each thing as a file named by its hash. It is the
// smallest store that does not hold a tree in memory, and it shows what a
// store has to do: keep bytes under a hash, and give them back.

import Foundation
import ScionicMerkleTree
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A store that keeps each thing as a file named by its hash.
///
/// It asks the system for each file itself, as the Go and Rust examples do
/// through their standard libraries: Foundation's calls for files cost several
/// times as much on Windows, and a store is asked for every chunk.
final class FolderStore: Store, @unchecked Sendable {
    /// Where the files are kept. On Windows it is whole and in the long form,
    /// `\\?\C:\...`, so that Windows takes a path of any length.
    let folder: String
    /// One writer at a time keeps a thing, by the start of its hash. Two
    /// writers of the same thing would otherwise each put a file in its place,
    /// and the second would put it in the place of a file that someone may be
    /// reading, which Windows does not allow.
    private let writing = (0..<1024).map { _ in NSLock() }
    /// Memory that things are read into, kept for the next read: fresh memory
    /// for each chunk, as `get` takes, costs some systems more than the reading
    /// does. One for each thread that reads at once, under `spare`.
    private var buffers: [[UInt8]] = []
    private let spare = NSLock()

    init(_ folder: String) {
        #if os(Windows)
        self.folder = longForm(folder)
        #else
        self.folder = folder
        #endif
    }

    /// The folder that holds a thing, and the file that it is kept as.
    func place(_ kind: Stored, _ hash: Hash) -> (folder: String, file: String) {
        let kept: String
        switch kind {
        case .chunk: kept = "chunks"
        case .fileList: kept = "files"
        case .folderList: kept = "folders"
        case .record: kept = "records"
        }
        let name = hash.hex
        let inside = folder + separator + kept + separator + String(name.prefix(2))
        return (inside, inside + separator + name)
    }

    /// Keeps bytes under hash. Keeping what is kept already changes nothing.
    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        let lock = writing[hash.withUnsafeBytes { Int($0[0]) << 8 | Int($0[1]) } % writing.count]
        lock.lock()
        defer { lock.unlock() }
        let place = self.place(kind, hash)
        if exists(place.file) {
            return
        }
        // Looked at first: trying to make a folder that is there already costs
        // several times what seeing that it is there does.
        if !exists(place.folder) {
            try makeFolders(place.folder)
        }
        // Written under another name first, so that a file is never found under
        // a hash before all of its bytes are there. The bytes are written from
        // where they are, without a copy.
        let unfinished = place.file + ".writing-" + UUID().uuidString
        do {
            try createFile(unfinished, with: bytes)
        } catch {
            try? removeFile(unfinished)
            throw error
        }
        if !rename(unfinished, to: place.file) {
            try? removeFile(unfinished)
            // Another program kept the same thing meanwhile, and that is no error.
            if !exists(place.file) {
                throw DiskError(what: "keep", path: place.file, code: nil)
            }
        }
    }

    /// What is kept under hash, if anything.
    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try readWhole(place(kind, hash).file)
    }

    /// Lends what is kept under hash, read into memory that was read into
    /// before. The library reads a tree's chunks this way.
    func lend(_ kind: Stored, _ hash: Hash, to body: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
        guard let file = try FileToRead(place(kind, hash).file) else {
            return false
        }
        var buffer = spare.withLock { buffers.popLast() } ?? []
        defer { spare.withLock { buffers.append(buffer) } }
        if buffer.count < file.length {
            buffer = [UInt8](repeating: 0, count: file.length)
        }
        try buffer.withUnsafeMutableBytes { raw in
            let room = UnsafeMutableRawBufferPointer(rebasing: raw[0..<file.length])
            try file.readAll(into: room)
            try body(UnsafeRawBufferPointer(room))
        }
        return true
    }

    /// The library reads chunks that it sends, or reads several at once,
    /// through here, straight into memory of its own. A file of another
    /// length than that memory is not read.
    func readInto(_ kind: Stored, _ hash: Hash, _ into: UnsafeMutableRawBufferPointer) throws -> UInt64? {
        guard let file = try FileToRead(place(kind, hash).file) else {
            return nil
        }
        if file.length == into.count {
            try file.readAll(into: into)
        }
        return UInt64(file.length)
    }

    /// How many bytes are kept under hash, without reading them. A store need
    /// not have this: the library asks it when it is there, and reads the
    /// whole thing when it is not.
    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        try sizeOf(place(kind, hash).file)
    }

    /// Forgets what is kept under hash.
    func remove(_ kind: Stored, _ hash: Hash) throws {
        try removeFile(place(kind, hash).file)
    }
}

/// A call to the system that failed.
struct DiskError: Error, CustomStringConvertible {
    let what: String
    let path: String
    let code: Int?

    var description: String {
        "could not \(what) \(path)" + (code.map { ": the system gave error \($0)" } ?? "")
    }
}

#if os(Windows)
private let separator = "\\"
private let genericRead: DWORD = 0x8000_0000
private let genericWrite: DWORD = 0x4000_0000
private let shareReadAndDelete: DWORD = 0x1 | 0x4
private let createNew: DWORD = 1
private let openExisting: DWORD = 3
private let attributeNormal: DWORD = 0x80
private let sequentialScan: DWORD = 0x0800_0000
private let noSuchFile: DWORD = 2
private let noSuchPath: DWORD = 3
private let alreadyThere: DWORD = 183
private let noAttributes: DWORD = 0xFFFF_FFFF

private func wide(_ path: String) -> [UInt16] {
    Array(path.utf16) + [0]
}

private func isInvalid(_ handle: HANDLE?) -> Bool {
    handle == nil || handle == HANDLE(bitPattern: -1)
}

/// `path` whole, in the long form that Windows takes as it is written.
func longForm(_ path: String) -> String {
    let given = wide(path)
    let length = GetFullPathNameW(given, 0, nil, nil)
    var whole = [UInt16](repeating: 0, count: Int(length))
    let written = GetFullPathNameW(given, length, &whole, nil)
    let full = String(decoding: whole.prefix(Int(written)), as: UTF16.self)
    if full.hasPrefix("\\\\?\\") {
        return full
    }
    if full.hasPrefix("\\\\") {
        return "\\\\?\\UNC\\" + full.dropFirst(2)
    }
    return "\\\\?\\" + full
}

/// A file that is open to be read, and is closed when it is let go of.
final class FileToRead {
    let path: String
    /// How many bytes the file holds.
    let length: Int
    private let handle: HANDLE?

    /// The file at `path`, or nil if there is none.
    init?(_ path: String) throws {
        let handle = CreateFileW(wide(path), genericRead, shareReadAndDelete, nil, openExisting, sequentialScan, nil)
        if isInvalid(handle) {
            let code = GetLastError()
            if code == noSuchFile || code == noSuchPath {
                return nil
            }
            throw DiskError(what: "open", path: path, code: Int(code))
        }
        var length = LARGE_INTEGER()
        guard GetFileSizeEx(handle, &length) else {
            let code = GetLastError()
            CloseHandle(handle)
            throw DiskError(what: "look at", path: path, code: Int(code))
        }
        self.path = path
        self.length = Int(length.QuadPart)
        self.handle = handle
    }

    deinit {
        CloseHandle(handle)
    }

    /// Reads the whole file into `room`, which is as long as the file.
    func readAll(into room: UnsafeMutableRawBufferPointer) throws {
        var done = 0
        while done < length {
            var read: DWORD = 0
            guard ReadFile(handle, room.baseAddress! + done, DWORD(min(length - done, 1 << 30)), &read, nil), read > 0 else {
                throw DiskError(what: "read", path: path, code: Int(GetLastError()))
            }
            done += Int(read)
        }
    }
}

/// A new file at `path` with `bytes` in it. Nothing may be there yet.
func createFile(_ path: String, with bytes: UnsafeRawBufferPointer) throws {
    let handle = CreateFileW(wide(path), genericWrite, 0, nil, createNew, attributeNormal, nil)
    if isInvalid(handle) {
        throw DiskError(what: "make", path: path, code: Int(GetLastError()))
    }
    defer { CloseHandle(handle) }
    var done = 0
    while done < bytes.count {
        var written: DWORD = 0
        guard WriteFile(handle, bytes.baseAddress! + done, DWORD(min(bytes.count - done, 1 << 30)), &written, nil), written > 0 else {
            throw DiskError(what: "write", path: path, code: Int(GetLastError()))
        }
        done += Int(written)
    }
}

/// How long the file at `path` is, or nil if there is none.
func sizeOf(_ path: String) throws -> UInt64? {
    var data = WIN32_FILE_ATTRIBUTE_DATA()
    guard GetFileAttributesExW(wide(path), GetFileExInfoStandard, &data) else {
        let code = GetLastError()
        if code == noSuchFile || code == noSuchPath {
            return nil
        }
        throw DiskError(what: "look at", path: path, code: Int(code))
    }
    return UInt64(data.nFileSizeHigh) << 32 | UInt64(data.nFileSizeLow)
}

/// Whether anything is at `path`.
func exists(_ path: String) -> Bool {
    GetFileAttributesW(wide(path)) != noAttributes
}

/// Removes the file at `path`, which need not be there.
func removeFile(_ path: String) throws {
    if !DeleteFileW(wide(path)) {
        let code = GetLastError()
        if code != noSuchFile && code != noSuchPath {
            throw DiskError(what: "remove", path: path, code: Int(code))
        }
    }
}

/// Makes the folder at `path`, and the folders above it that are not there.
func makeFolders(_ path: String) throws {
    if CreateDirectoryW(wide(path), nil) {
        return
    }
    let code = GetLastError()
    if code == alreadyThere {
        return
    }
    guard code == noSuchPath, let cut = path.lastIndex(of: "\\"), cut > path.startIndex else {
        throw DiskError(what: "make the folder", path: path, code: Int(code))
    }
    try makeFolders(String(path[..<cut]))
    if !CreateDirectoryW(wide(path), nil) && GetLastError() != alreadyThere {
        throw DiskError(what: "make the folder", path: path, code: Int(GetLastError()))
    }
}
#else
private let separator = "/"

/// A file that is open to be read, and is closed when it is let go of.
final class FileToRead {
    let path: String
    /// How many bytes the file holds.
    let length: Int
    private let fd: Int32

    /// The file at `path`, or nil if there is none.
    init?(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT {
                return nil
            }
            throw DiskError(what: "open", path: path, code: Int(errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            _ = close(fd)
            throw DiskError(what: "look at", path: path, code: Int(code))
        }
        self.path = path
        self.length = Int(info.st_size)
        self.fd = fd
    }

    deinit {
        _ = close(fd)
    }

    /// Reads the whole file into `room`, which is as long as the file.
    func readAll(into room: UnsafeMutableRawBufferPointer) throws {
        var done = 0
        while done < length {
            let got = read(fd, room.baseAddress! + done, length - done)
            if got < 0 && errno == EINTR {
                continue
            }
            guard got > 0 else {
                throw DiskError(what: "read", path: path, code: Int(errno))
            }
            done += got
        }
    }
}

/// A new file at `path` with `bytes` in it. Nothing may be there yet.
func createFile(_ path: String, with bytes: UnsafeRawBufferPointer) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
        throw DiskError(what: "make", path: path, code: Int(errno))
    }
    defer { _ = close(fd) }
    var done = 0
    while done < bytes.count {
        let wrote = write(fd, bytes.baseAddress! + done, bytes.count - done)
        if wrote < 0 && errno == EINTR {
            continue
        }
        guard wrote > 0 else {
            throw DiskError(what: "write", path: path, code: Int(errno))
        }
        done += wrote
    }
}

/// How long the file at `path` is, or nil if there is none.
func sizeOf(_ path: String) throws -> UInt64? {
    var info = stat()
    if stat(path, &info) != 0 {
        if errno == ENOENT {
            return nil
        }
        throw DiskError(what: "look at", path: path, code: Int(errno))
    }
    return UInt64(info.st_size)
}

/// Whether anything is at `path`.
func exists(_ path: String) -> Bool {
    access(path, F_OK) == 0
}

/// Removes the file at `path`, which need not be there.
func removeFile(_ path: String) throws {
    if unlink(path) != 0 && errno != ENOENT {
        throw DiskError(what: "remove", path: path, code: Int(errno))
    }
}

/// Makes the folder at `path`, and the folders above it that are not there.
func makeFolders(_ path: String) throws {
    if mkdir(path, 0o777) == 0 || errno == EEXIST {
        return
    }
    guard errno == ENOENT, let cut = path.lastIndex(of: "/"), cut > path.startIndex else {
        throw DiskError(what: "make the folder", path: path, code: Int(errno))
    }
    try makeFolders(String(path[..<cut]))
    if mkdir(path, 0o777) != 0 && errno != EEXIST {
        throw DiskError(what: "make the folder", path: path, code: Int(errno))
    }
}
#endif

/// The whole of the file at `path`, or nil if there is none.
func readWhole(_ path: String) throws -> [UInt8]? {
    guard let file = try FileToRead(path) else {
        return nil
    }
    return try [UInt8](unsafeUninitializedCapacity: file.length) { buffer, initialized in
        try file.readAll(into: UnsafeMutableRawBufferPointer(buffer))
        initialized = file.length
    }
}

/// Gives a file another name in one step, with the system's own call, which
/// does not wait for the disk as Foundation's `moveItem` does on Windows.
func rename(_ from: String, to: String) -> Bool {
    #if os(Windows)
    return from.withCString(encodedAs: UTF16.self) { old in
        to.withCString(encodedAs: UTF16.self) { new in _wrename(old, new) == 0 }
    }
    #else
    return from.withCString { old in to.withCString { new in Foundation.rename(old, new) == 0 } }
    #endif
}

/// The largest file of a tree, each folder looked into once.
func largestFile(_ store: any Store, _ top: Target) throws -> Target? {
    var largest: Target?
    var seen = Set<Hash>()
    var pending = [top]
    while let target = pending.popLast() {
        if target.kind == .file {
            if largest.map({ $0.size < target.size }) ?? true {
                largest = target
            }
            continue
        }
        if !seen.insert(target.hash).inserted {
            continue
        }
        for entry in try folderOf(store, target).entries {
            pending.append(entry.target)
        }
    }
    return largest
}

/// How many seconds have gone by since `started`.
func seconds(since started: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
}

func report<Out: TextOutputStream>(_ out: inout Out, _ step: String, _ started: DispatchTime, _ size: UInt64) {
    let taken = seconds(since: started)
    let rate = Double(size) / Double(1 << 20) / max(taken, 1e-9)
    print(step.padding(toLength: 12, withPad: " ", startingAt: 0) + " " + String(format: "%8.2f s  %8.0f MiB/s", taken, rate), to: &out)
}

/// The copy came back as another tree.
struct NotTheSame: Error, CustomStringConvertible {
    let description: String
}

/// Takes the folder its whole way round, with its stores and its copy in the
/// new folder `work`, and gives the tree's root.
func roundtrip<Out: TextOutputStream>(_ folder: String, _ work: String, to out: inout Out) throws -> Root {
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false)

    let source = FolderStore(work + "/source-store")
    var started = DispatchTime.now()
    let root = try build(source, path: folder)
    let record = try recordOf(source, root)
    let size = record.top.size
    let totals = record.totals
    report(&out, "built", started, size)
    print("root         \(root)", to: &out)
    print("the tree     \(size) bytes; kept once: \(totals.chunks) chunks of \(totals.chunkBytes) bytes, and \(totals.listBytes) bytes of lists", to: &out)

    started = DispatchTime.now()
    let summary = try verify(source, root)
    report(&out, "checked", started, totals.chunkBytes)
    print("             \(summary.files) different files in \(summary.folders) different folders", to: &out)

    let fetched = FolderStore(work + "/fetched-store")
    started = DispatchTime.now()
    _ = try fetch(fetched, root, from: Responder(source))
    report(&out, "fetched", started, totals.chunkBytes)

    if let file = try largestFile(source, record.top) {
        // A stretch of 4 KiB is read from 64 places spread over the file, each
        // asked for on its own, and the time one takes on average is printed: a
        // single read is shorter than some systems' clocks can tell apart.
        let length = min(file.size, 4096)
        let places: UInt64 = 64
        let remote = try Remote(peer: Responder(source), root: root)
        let stretch = MemorySink()
        started = DispatchTime.now()
        for place in 0..<places {
            stretch.bytes.removeAll(keepingCapacity: true)
            try remote.read(file, offset: (file.size - length) * place / (places - 1), length: length, to: stretch)
        }
        let taken = String(format: "%8.4f", seconds(since: started) / Double(places))
        print("a stretch    \(taken) s  \(stretch.bytes.count) bytes at a time, from \(places) places in a file of \(file.size) bytes", to: &out)
    }

    let written = work + "/written"
    started = DispatchTime.now()
    try writeToDisk(fetched, root, to: written)
    report(&out, "written out", started, size)

    let again = FolderStore(work + "/again-store")
    started = DispatchTime.now()
    let rebuilt = try build(again, path: written)
    report(&out, "built again", started, size)
    guard rebuilt == root else {
        throw NotTheSame(description: "the copy has the root \(rebuilt), and not \(root)")
    }
    print("the copy has the same root", to: &out)
    return root
}

/// What the program prints, as it comes.
struct Standard: TextOutputStream {
    mutating func write(_ text: String) {
        Swift.print(text, terminator: "")
    }
}

@main
struct Roundtrip {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: roundtrip <folder> <work-dir>\n".utf8))
            exit(2)
        }
        var out = Standard()
        do {
            _ = try roundtrip(arguments[1], arguments[2], to: &out)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
