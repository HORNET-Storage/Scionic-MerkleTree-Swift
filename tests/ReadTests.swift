// Reading a tree that a store holds, and writing it out to disk.

import Foundation
import XCTest
@testable import ScionicMerkleTree

private func entry(_ name: String, _ target: Target) throws -> Entry {
    try Entry(name: name, target: target)
}

/// Every file under `folder`, by its path from there, with its bytes. A folder
/// is listed with a `/` after its name, and no bytes.
private func filesUnder(_ folder: String) throws -> [String] {
    var files: [String] = []
    var pending: [(String, String)] = [(folder, "")]
    while let (path, prefix) = pending.popLast() {
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            let child = path + "/" + name
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: child, isDirectory: &isFolder)
            if isFolder.boolValue {
                pending.append((child, prefix + name + "/"))
                files.append(prefix + name + "/")
            } else {
                files.append(prefix + name + " " + hexText(try fileBytes(child)))
            }
        }
    }
    return files.sorted()
}

private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

final class ReadTests: XCTestCase {
    func testAStretchIsReadFromAnOpenFileWithoutAPassOverItsList() throws {
        let store = MemoryStore()
        let data = corpusBytes("open", 100)
        let file = try Builder(store: store, chunking: smallChunks()).file(bytes: data)
        let open = try OpenFile(fileOf(store, file))
        for offset in 0...100 {
            for length in 0...(100 - offset) {
                let out = BytesSink()
                try readOpen(store, open, offset: UInt64(offset), length: UInt64(length), to: out)
                XCTAssertEqual(out.bytes, Array(data[offset..<(offset + length)]), "\(offset)+\(length)")
            }
        }
        let out = BytesSink()
        assertFails(try readOpen(store, open, offset: 0, length: 101, to: out))
        assertFails(try readOpen(store, open, offset: 101, length: 0, to: out))
        assertFails(try readOpen(store, open, offset: .max, length: 2, to: out))
        // A chunk that is missing: an error, and no byte.
        try store.remove(.chunk, open.list.items[3].hash)
        assertFails(try readOpen(store, open, offset: 40, length: 30, to: out), "missing")
        XCTAssertTrue(out.bytes.isEmpty)
        // An empty file has one stretch: none of its bytes, from its start.
        let empty = try Builder(store: store, chunking: smallChunks()).file(bytes: [])
        let openEmpty = try OpenFile(fileOf(store, empty))
        try readOpen(store, openEmpty, offset: 0, length: 0, to: out)
        assertFails(try readOpen(store, openEmpty, offset: 0, length: 1, to: out))
        XCTAssertTrue(out.bytes.isEmpty)
    }

    func testASmallTreeThatStandsForMoreFoldersThanADiskHoldsIsNotWritten() throws {
        let temp = try TempDir("read-unfold")
        let store = MemoryStore()
        var builder = Builder(store: store, chunking: smallChunks())
        // An empty folder, and above it 100 folders that each hold the one below
        // under two names.
        var folder = try builder.folder([])
        for _ in 0..<100 {
            folder = try builder.folder([entry("a", folder), entry("b", folder)])
        }
        var root = try builder.finish(top: folder)
        // To hold and to check, it is a tree like any other: 101 small lists.
        XCTAssertEqual(store.count(.folderList), 101)
        XCTAssertEqual(try verify(store, root).folders, 101)

        // Written out, it would be more folders than there are numbers for.
        // They are counted, each folder once, before anything is made.
        let dest = temp.join("written")
        let error = assertFails(try writeToDisk(store, root, to: dest), "limitExceeded")
        if case let .limitExceeded(_, limit, requested)? = error {
            XCTAssertEqual(requested, .max)
            XCTAssertEqual(limit, Scionic.defaultMaxWrittenEntries)
        }
        XCTAssertFalse(exists(dest))

        // Twenty levels of it are counted exactly: 2^21 - 1 folders.
        builder = Builder(store: store, chunking: smallChunks())
        folder = try builder.folder([])
        for _ in 0..<20 {
            folder = try builder.folder([entry("a", folder), entry("b", folder)])
        }
        root = try builder.finish(top: folder)
        if case let .limitExceeded(_, _, requested)? = assertFails(try writeToDisk(store, root, to: dest), "limitExceeded") {
            XCTAssertEqual(requested, 2_097_151)
        }
        XCTAssertFalse(exists(dest))
    }

    func testWritingOutStaysWithinWhatItIsGiven() throws {
        let (temp, store, root) = try sampleTree("read-limits")
        let size = try recordOf(store, root).top.size
        // The tree is seven files and five folders, the top one counted.
        let cases: [(WriteOptions, Bool)] = [
            (WriteOptions(maxEntries: 11), false),
            (WriteOptions(maxBytes: size - 1), false),
            (WriteOptions(maxEntries: 12, maxBytes: size), true),
        ]
        for (number, (options, fits)) in cases.enumerated() {
            let dest = temp.join("written-\(number)")
            if fits {
                try writeToDisk(store, root, to: dest, options: options)
                XCTAssertTrue(exists(dest + "/weights/shards/a.bin"))
            } else {
                assertFails(try writeToDisk(store, root, to: dest, options: options), "limitExceeded")
                XCTAssertFalse(exists(dest), "nothing is made before the limits are held")
            }
        }

        // A file on top is one thing to make, and takes its own size.
        let file = try XCTUnwrap(lookup(store, root, path: "weights/model.bin")).target
        let alone = try Builder(store: store, chunking: smallChunks()).finish(top: file)
        let dest = temp.join("alone.bin")
        assertFails(try writeToDisk(store, alone, to: dest, options: WriteOptions(maxBytes: 999)))
        XCTAssertFalse(exists(dest))
        try writeToDisk(store, alone, to: dest, options: WriteOptions(maxEntries: 1, maxBytes: 1_000))
        XCTAssertEqual(try fileBytes(dest), corpusBytes("model", 1_000))
    }

    func testEveryStretchOfAFileReadsBack() throws {
        let store = MemoryStore()
        let data = corpusBytes("stretch", 100)
        let file = try Builder(store: store, chunking: smallChunks()).file(bytes: data)
        for offset in 0...100 {
            for length in 0...(100 - offset) {
                let out = BytesSink()
                try readRange(store, file, offset: UInt64(offset), length: UInt64(length), to: out)
                XCTAssertEqual(out.bytes, Array(data[offset..<(offset + length)]), "\(offset)+\(length)")
            }
        }
        XCTAssertEqual(try readFile(store, file), data)
        let out = BytesSink()
        assertFails(try readRange(store, file, offset: 0, length: 101, to: out))
        assertFails(try readRange(store, file, offset: 101, length: 0, to: out))
        assertFails(try readRange(store, file, offset: .max, length: 2, to: out))
        XCTAssertTrue(out.bytes.isEmpty)
    }

    func testAFileWithAChunkMissingGivesAnErrorAndNoBytes() throws {
        let store = MemoryStore()
        let data = corpusBytes("holed", 100)
        let file = try Builder(store: store, chunking: smallChunks()).file(bytes: data)
        // Chunk 3 holds bytes 48 to 63.
        let chunk = try fileOf(store, file).items[3]
        let honest = try XCTUnwrap(store.get(.chunk, chunk.hash))
        try store.remove(.chunk, chunk.hash)

        var out = BytesSink()
        assertFails(try readFile(store, file, to: out), "missing")
        XCTAssertTrue(out.bytes.isEmpty, "never a shorter file")
        assertFails(try readFile(store, file))
        for (offset, length): (UInt64, UInt64) in [(40, 10), (48, 1), (63, 1), (0, 100), (60, 40)] {
            assertFails(try readRange(store, file, offset: offset, length: length, to: out))
            XCTAssertTrue(out.bytes.isEmpty, "\(offset)+\(length)")
        }
        // What does not need the chunk is still read.
        try readRange(store, file, offset: 0, length: 48, to: out)
        try readRange(store, file, offset: 64, length: 36, to: out)
        XCTAssertEqual(out.bytes, Array(data[..<48]) + Array(data[64...]))

        // Other bytes under the chunk's hash are no chunk of the file.
        try store.put(.chunk, chunk.hash, corpusBytes("other", 16))
        assertFails(try readFile(store, file), "corrupt")
        try store.remove(.chunk, chunk.hash)
        try store.put(.chunk, chunk.hash, corpusBytes("other", 5))
        out = BytesSink()
        assertFails(try readFile(store, file, to: out), "sizeMismatch")
        XCTAssertTrue(out.bytes.isEmpty)
        try store.remove(.chunk, chunk.hash)
        try store.put(.chunk, chunk.hash, honest)
        XCTAssertEqual(try readFile(store, file), data)
    }

    func testAPathIsFoundOrItIsNot() throws {
        let (_, store, root) = try sampleTree("read-path")
        func found(_ path: String) throws -> Entry? {
            try lookup(store, root, path: path)
        }
        XCTAssertEqual(try found("readme.txt")?.kind, .file)
        XCTAssertEqual(try found("weights")?.kind, .folder)
        XCTAssertEqual(try found("weights/shards/b.bin")?.size, 33)
        XCTAssertEqual(try found("nothing-here")?.size, 0)
        for path in ["missing", "weights/missing", "weights/shards/b.bin/deeper", "readme.txt/x", "Readme.txt", "weights/shards/c.bin"] {
            XCTAssertNil(try found(path), path)
        }
        for path in ["", "/", "weights/", "/weights", "weights//shards", "weights/../readme.txt", "."] {
            assertFails(try lookup(store, root, path: path), nil, path)
        }
        assertFails(try lookup(store, Root.of(record: bytes("no such tree")), path: "readme.txt"))
    }

    func testATreeWrittenToDiskBuildsToTheSameRoot() throws {
        let (temp, store, root) = try sampleTree("read-write")
        let dest = temp.join("written")
        try writeToDisk(store, root, to: dest)
        XCTAssertEqual(try filesUnder(dest), try filesUnder(temp.join("sample")))
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest + "/nothing-here", isDirectory: &isFolder) && isFolder.boolValue)
        XCTAssertEqual(try build(MemoryStore(), path: dest, options: smallOptions()), root)

        // A place that is there already is never written into.
        let before = try filesUnder(dest)
        assertFails(try writeToDisk(store, root, to: dest))
        XCTAssertEqual(try filesUnder(dest), before)

        // A tree with a file on top is written as that file.
        let file = try XCTUnwrap(lookup(store, root, path: "weights/model.bin")).target
        let alone = try Builder(store: store, chunking: smallChunks()).finish(top: file)
        let destFile = temp.join("written.bin")
        try writeToDisk(store, alone, to: destFile)
        XCTAssertEqual(try fileBytes(destFile), corpusBytes("model", 1_000))
        assertFails(try writeToDisk(store, alone, to: destFile))
    }

    func testNothingIsWrittenWhenAPartIsMissing() throws {
        let (temp, store, root) = try sampleTree("read-missing")
        let shard = try XCTUnwrap(lookup(store, root, path: "weights/shards/b.bin")).target
        try store.remove(.chunk, fileOf(store, shard).items[2].hash)
        let dest = temp.join("written")
        assertFails(try writeToDisk(store, root, to: dest), "missing")
        XCTAssertFalse(exists(dest), "the lack is found before anything is written")
    }

    func testTwoNamesThatOneSystemTakesForOneAreRefusedThere() throws {
        let temp = try TempDir("read-fold")
        // Whether this system takes `Probe` and `probe` for one name.
        try writeFile(temp.join("Probe"), bytes("x"))
        let folds = exists(temp.join("probe"))
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let upper = try builder.file(bytes: bytes("under the capital"))
        let lower = try builder.file(bytes: bytes("under the small letter"))
        let inner = try builder.folder([entry("x", upper)])
        let cases: [(String, [Entry])] = [
            ("two-files", [try entry("File", upper), try entry("file", lower)]),
            ("file-and-folder", [try entry("Name", inner), try entry("name", lower)]),
            ("two-folders", [try entry("Dir", inner), try entry("dir", inner)]),
        ]
        for (name, entries) in cases {
            let builder = Builder(store: store, chunking: smallChunks())
            // Held in a tree, the two names are two names.
            let root = try builder.finish(top: builder.folder(entries))
            let dest = temp.join(name)
            if folds {
                let error = assertFails(try writeToDisk(store, root, to: dest), "unwritableName", name)
                if case let .unwritableName(written, _)? = error {
                    XCTAssertTrue(entries.contains { $0.name == written }, written)
                }
            } else {
                try writeToDisk(store, root, to: dest)
                XCTAssertEqual(try build(MemoryStore(), path: dest, options: smallOptions()), root)
            }
        }
    }

    func testNamesThatWindowsCannotHoldAreFound() {
        for name in [
            "a", "a.b", ".git", "a b", "com", "com10", "nul1", "console", "aux2", "lpt", "\u{E9}t\u{E9}",
            "model.safetensors", "a.b.c", "con1.txt", "$con",
        ] {
            XCTAssertNil(unwritableOnWindows(name), name)
        }
        for name in [
            "a:b", "a\\b", "a/b", "a?", "a*", "a<b", "a>b", "a|b", "a\"b", "a\tb", "a\u{1}", "a.", "a ", "...",
            "CON", "con", "Nul", "nul.txt", "NUL.tar.gz", "NUL .txt", "COM1", "com9.txt", "COM0", "LPT1",
            "lpt3.x", "COM\u{B9}", "lpt\u{B3}", "AUX", "PRN", "CONIN$", "conout$",
        ] {
            XCTAssertNotNil(unwritableOnWindows(name), name)
        }
    }

    func testANameThisSystemCannotHoldIsRefusedBeforeAnythingIsWritten() throws {
        let temp = try TempDir("read-names")
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let file = try builder.file(bytes: bytes("content"))
        let inner = try builder.folder([entry("fine", file), entry("nul.txt", file)])
        let top = try builder.folder([entry("a-fine-name", file), entry("sub", inner)])
        let root = try builder.finish(top: top)
        let dest = temp.join("written")
        #if os(Windows)
        if case let .unwritableName(name, _)? = assertFails(try writeToDisk(store, root, to: dest), "unwritableName") {
            XCTAssertEqual(name, "nul.txt")
        }
        XCTAssertFalse(exists(dest), "the name is found before anything is written")
        #else
        try writeToDisk(store, root, to: dest)
        XCTAssertEqual(try fileBytes(dest + "/sub/nul.txt"), bytes("content"))
        #endif
    }
}
