// Roundtrip takes a tree its whole way round, with a store on disk.
//
// It builds a tree from a folder, checks it, fetches it into a second store
// as a receiver would, reads a stretch from the middle of its largest file
// without the rest, writes the tree out again, and holds the copy to the
// same root. It prints how long each step took.
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

/// A store that keeps each thing as a file named by its hash.
final class FolderStore: Store, @unchecked Sendable {
    let folder: String
    /// One writer at a time keeps a thing, by the start of its hash. Two
    /// writers of the same thing would otherwise each put a file in its place,
    /// and the second would put it in the place of a file that someone may be
    /// reading, which Windows does not allow.
    private let writing = (0..<1024).map { _ in NSLock() }

    init(_ folder: String) {
        self.folder = folder
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
        let inside = folder + "/" + kept + "/" + String(name.prefix(2))
        return (inside, inside + "/" + name)
    }

    /// Keeps bytes under hash. Keeping what is kept already changes nothing.
    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        let lock = writing[hash.withUnsafeBytes { Int($0[0]) << 8 | Int($0[1]) } % writing.count]
        lock.lock()
        defer { lock.unlock() }
        let place = self.place(kind, hash)
        if FileManager.default.fileExists(atPath: place.file) {
            return
        }
        try FileManager.default.createDirectory(atPath: place.folder, withIntermediateDirectories: true)
        // Written under another name first, so that a file is never found under
        // a hash before all of its bytes are there. The bytes are written from
        // where they are, without a copy.
        let unfinished = place.file + ".writing-" + UUID().uuidString
        guard FileManager.default.createFile(atPath: unfinished, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: unfinished])
        }
        do {
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: unfinished))
            do {
                try file.write(contentsOf: bytes)
            } catch {
                try? file.close()
                throw error
            }
            try file.close()
        } catch {
            try? FileManager.default.removeItem(atPath: unfinished)
            throw error
        }
        if !rename(unfinished, to: place.file) {
            try? FileManager.default.removeItem(atPath: unfinished)
            // Another program kept the same thing meanwhile, and that is no error.
            if !FileManager.default.fileExists(atPath: place.file) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: place.file])
            }
        }
    }

    /// What is kept under hash, if anything.
    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        do {
            return [UInt8](try Data(contentsOf: URL(fileURLWithPath: place(kind, hash).file)))
        } catch let error as CocoaError where isMissing(error) {
            return nil
        }
    }

    /// How many bytes are kept under hash, without reading them. A store need
    /// not have this: the library asks it when it is there, and reads the
    /// whole thing when it is not.
    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: place(kind, hash).file)
        } catch let error as CocoaError where isMissing(error) {
            return nil
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.uint64Value
    }

    /// Forgets what is kept under hash.
    func remove(_ kind: Stored, _ hash: Hash) throws {
        do {
            try FileManager.default.removeItem(atPath: place(kind, hash).file)
        } catch let error as CocoaError where isMissing(error) {
            // It was not there, and it is not there now.
        }
    }
}

/// Whether an error says that there was no such file.
func isMissing(_ error: CocoaError) -> Bool {
    error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
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
        let length = min(file.size, 4096)
        let remote = try Remote(peer: Responder(source), root: root)
        let stretch = MemorySink()
        started = DispatchTime.now()
        try remote.read(file, offset: (file.size - length) / 2, length: length, to: stretch)
        let taken = String(format: "%8.4f", seconds(since: started))
        print("a stretch    \(taken) s  \(stretch.bytes.count) bytes from the middle of a file of \(file.size) bytes", to: &out)
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
