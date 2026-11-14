// Building a tree, and what the format promises about it: the same things have
// the same hashes wherever they are, and are stored once.

import Foundation
import XCTest
@testable import ScionicMerkleTree
#if os(Windows)
import WinSDK
#endif

private func expectError(_ body: () throws -> Void, _ matches: (ScionicError) -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        try body()
        XCTFail("no error: \(message)", file: file, line: line)
    } catch let error as ScionicError {
        XCTAssertTrue(matches(error), "\(error) \(message)", file: file, line: line)
    } catch {
        XCTFail("\(error) \(message)", file: file, line: line)
    }
}

/// A path with `/` between its names, as the tests write it.
private func slashed(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
}

final class BuildTests: XCTestCase {
    func testAFolderHasTheSameRootWhereverItIsAndWhateverItIsCalled() throws {
        let temp = try TempDir("same-root")
        let first = try sampleFolder(temp.path, "one")
        let second = try sampleFolder(temp.join("deeper/still"), "another-name")
        let (storeA, storeB) = (MemoryStore(), MemoryStore())
        let rootA = try build(storeA, path: first, options: smallOptions())
        let rootB = try build(storeB, path: second, options: smallOptions())
        XCTAssertEqual(rootA, rootB)
        XCTAssertEqual(try contents(storeA), try contents(storeB))

        // The same folder, named by another path to it.
        let storeC = MemoryStore()
        XCTAssertEqual(try build(storeC, path: first + "/weights/..", options: smallOptions()), rootA)
        XCTAssertTrue(rootA.text.hasPrefix("bafkrei"))
    }

    func testTheRootIsWhatTheFormatSaysItIs() throws {
        let temp = try TempDir("oracle")
        let top = temp.join("tree")
        let a = bytes("hello")
        let b = corpusBytes("b", 40)
        try writeFile(top + "/a.txt", a)
        try writeFile(top + "/sub/b.bin", b)
        try writeFile(top + "/sub/empty", [])
        let store = MemoryStore()
        let root = try build(store, path: top, options: smallOptions())

        // The same tree by the rules, written out by hand.
        let aItems = [Oracle.Item.of(a)]
        let bItems = stride(from: 0, to: b.count, by: 16).map { Oracle.Item.of(Array(b[$0..<min($0 + 16, b.count)])) }
        XCTAssertEqual(bItems.count, 3)
        let (aHash, aSize) = Oracle.fileHash(aItems)
        let (bHash, bSize) = Oracle.fileHash(bItems)
        let (emptyHash, _) = Oracle.fileHash([])
        let sub = [Oracle.Entry.file("b.bin", bHash, bSize), Oracle.Entry.file("empty", emptyHash, 0)]
        let (subHash, subSize) = Oracle.folderHash(sub)
        let tree = [Oracle.Entry.file("a.txt", aHash, aSize), Oracle.Entry.folder("sub", subHash, subSize)]
        let (topHash, topSize) = Oracle.folderHash(tree)
        XCTAssertEqual([aSize, bSize, subSize, topSize], [5, 40, 40, 45])
        let listBytes = UInt64(36 + 3 * 36 + Oracle.folderListBytes(sub).count + Oracle.folderListBytes(tree).count)
        let record = Oracle.recordBytes(2, 45, topHash, (4, 45, listBytes), Oracle.chunkingTag("fixed-16"))

        XCTAssertEqual(root.hash.bytes, Oracle.sha(record))
        func kept(_ kind: Stored, _ hash: [UInt8]) throws -> [UInt8]? {
            try store.get(kind, Hash(bytes: hash))
        }
        XCTAssertEqual(try kept(.record, root.hash.bytes), record)
        XCTAssertEqual(try kept(.folderList, topHash), Oracle.folderListBytes(tree))
        XCTAssertEqual(try kept(.folderList, subHash), Oracle.folderListBytes(sub))
        XCTAssertEqual(try kept(.fileList, bHash), Oracle.fileListBytes(bItems))
        XCTAssertEqual(try kept(.fileList, emptyHash), [])
        XCTAssertEqual(try kept(.chunk, bItems[2].hash), Array(b[32...]))
        // A chunk's hash is the plain SHA-256 of its bytes.
        XCTAssertEqual(Hash.of(a).hex, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try kept(.chunk, aItems[0].hash), a)
    }

    func testIdenticalThingsAreStoredOnce() throws {
        let (_, store, root) = try sampleTree("stored-once")
        // Two names, one file: the same hash, one list, and its chunks once.
        let model = try XCTUnwrap(lookup(store, root, path: "weights/model.bin"))
        let copy = try XCTUnwrap(lookup(store, root, path: "weights/copy-of-model.bin"))
        XCTAssertEqual(model.hash, copy.hash)
        XCTAssertEqual(model.target, copy.target)

        let summary = try verify(store, root)
        let totals = summary.record.totals
        XCTAssertEqual(summary.files, 6)
        XCTAssertEqual(summary.folders, 5)
        XCTAssertEqual(store.count(.fileList), 6)
        XCTAssertEqual(store.count(.folderList), 5)
        XCTAssertEqual(store.count(.record), 1)
        // 12, 1,000, 100, 33 and 32 bytes in chunks of 16.
        XCTAssertEqual(totals.chunks, 1 + 63 + 7 + 3 + 2)
        XCTAssertEqual(totals.chunkBytes, 12 + 1_000 + 100 + 33 + 32)
        XCTAssertEqual(UInt64(store.count(.chunk)), totals.chunks)
        XCTAssertEqual(store.bytes(.chunk), totals.chunkBytes)
        XCTAssertEqual(store.bytes(.fileList) + store.bytes(.folderList), totals.listBytes)
        // The tree's size counts the file under both of its names.
        XCTAssertEqual(summary.record.top.size, totals.chunkBytes + 1_000)
        XCTAssertEqual(summary.record.top.kind, .folder)
    }

    func testASecondTreeAddsOnlyWhatIsNew() throws {
        let temp = try TempDir("second-tree")
        let folder = try sampleFolder(temp.path, "sample")
        let store = MemoryStore()
        let first = try build(store, path: folder, options: smallOptions())
        let before = [store.count(.chunk), store.count(.fileList), store.count(.folderList)]

        // One chunk of one file changes, and another file gets a new name.
        var model = corpusBytes("model", 1_000)
        model.replaceSubrange(320..<336, with: corpusBytes("changed", 16))
        try writeFile(folder + "/weights/model.bin", model)
        try FileManager.default.moveItem(atPath: folder + "/readme.txt", toPath: folder + "/notes.txt")
        let second = try build(store, path: folder, options: smallOptions())
        XCTAssertNotEqual(first, second)

        let after = [store.count(.chunk), store.count(.fileList), store.count(.folderList)]
        // One new chunk. One new list for the changed file: the renamed file is
        // the same file. Two new folders: the one that holds the change, and the
        // top, which holds both.
        XCTAssertEqual(after, [before[0] + 1, before[1] + 1, before[2] + 2])
        _ = try verify(store, first)
        _ = try verify(store, second)
        let renamed = try XCTUnwrap(lookup(store, second, path: "notes.txt"))
        let original = try XCTUnwrap(lookup(store, first, path: "readme.txt"))
        XCTAssertEqual(renamed.hash, original.hash)
        XCTAssertNil(try lookup(store, second, path: "readme.txt"))
        // What did not change has the same hash in both trees.
        for path in ["weights/shards", "data", "weights/copy-of-model.bin", "nothing-here"] {
            XCTAssertEqual(try lookup(store, first, path: path), try lookup(store, second, path: path), path)
        }
    }

    func testAFileThatRepeatsAChunkReadsBackWhole() throws {
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let (x, y) = (corpusBytes("x", 16), corpusBytes("y", 16))
        let content = x + y + x
        let file = try builder.file(bytes: content)
        XCTAssertEqual(store.count(.chunk), 2)

        let list = try fileOf(store, file)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.items[0], list.items[2])
        XCTAssertEqual(try readFile(store, file), content)
        // Each of the three places is shown on its own, at its own byte.
        for place: UInt64 in 0..<3 {
            let branch = try list.open(start: place, end: place + 1)
            XCTAssertEqual(try branch.check(file: file, chunking: smallChunks()), place * 16)
        }

        let root = try builder.finish(top: file)
        let summary = try verify(store, root)
        let totals = summary.record.totals
        XCTAssertEqual(summary.record.top.size, 48)
        XCTAssertEqual([totals.chunks, totals.chunkBytes, totals.listBytes], [2, 32, 108])
    }

    func testTheSameChunkInTwoFilesIsOneChunk() throws {
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let shared = corpusBytes("shared", 16)
        let first = try builder.file(bytes: shared + corpusBytes("first", 10))
        let second = try builder.file(bytes: corpusBytes("second", 16) + shared)
        XCTAssertNotEqual(first.hash, second.hash)
        XCTAssertEqual(store.count(.chunk), 3)
        let top = try builder.folder([
            Entry(name: "second", target: second),
            Entry(name: "first", target: first),
        ])
        let root = try builder.finish(top: top)
        let totals = try verify(store, root).record.totals
        XCTAssertEqual([totals.chunks, totals.chunkBytes], [3, 42])
        // The builder sorted the entries by name.
        XCTAssertEqual(try folderOf(store, top).entries.map(\.name), ["first", "second"])
    }

    func testBuildingWithSeveralWorkersGivesTheSameTree() throws {
        let temp = try TempDir("workers")
        let top = temp.join("many")
        for index in 0..<40 {
            try writeFile(top + "/d\(index % 5)/f\(padded(index, 2)).bin", corpusBytes("file-\(index % 30)", index * 37))
        }
        var built: [(MemoryStore, Root)] = []
        for workers in [1, 2, 7, 0] {
            let store = MemoryStore()
            built.append((store, try build(store, path: top, options: BuildOptions(chunking: smallChunks(), workers: workers))))
        }
        for (store, root) in built {
            XCTAssertEqual(root, built[0].1)
            XCTAssertEqual(try contents(store), try contents(built[0].0))
            _ = try verify(store, root)
        }
    }

    func testFilesAreChunkedByContentUnlessATestSaysOtherwise() throws {
        // A case of the committed chunking vectors: 3 MiB, cut after 2,118,489.
        let data = corpusBytes("scionic-fastcdc-v1:corpus:random_3mib", 3 << 20)
        let temp = try TempDir("by-content")
        let path = temp.join("random.bin")
        try writeFile(path, data)
        let store = MemoryStore()
        let root = try build(store, path: path)
        let record = try recordOf(store, root)
        XCTAssertEqual(record.chunking, .fastCDCv1)
        XCTAssertEqual(record.extra.text(Scionic.chunkingKey), "fastcdc-v1")
        XCTAssertEqual(record.extra.count, 1)
        XCTAssertEqual(record.top.kind, .file)
        XCTAssertEqual(try fileOf(store, record.top).items.map(\.length), [2_118_489, UInt32(3 << 20) - 2_118_489])
        _ = try verify(store, root)

        // The same bytes, by the builder that is given bytes: the same file.
        XCTAssertEqual(try Builder(store: MemoryStore(), chunking: .fastCDCv1).file(bytes: data), record.top)
    }

    func testTheRecordCarriesWhatTheBuilderWasTold() throws {
        let (temp, plainStore, plain) = try sampleTree("record-extra")
        let folder = temp.join("sample")
        let store = MemoryStore()
        let extra = try ExtraData()
            .with("name", text: "my model")
            .with(Scionic.chunkingKey, text: "not for a caller to say")
        let root = try build(store, path: folder, options: BuildOptions(chunking: smallChunks(), extra: extra, timestamp: true))
        XCTAssertNotEqual(root, plain)
        let record = try recordOf(store, root)
        XCTAssertEqual(record.extra.text("name"), "my model")
        XCTAssertEqual(record.extra.text(Scionic.chunkingKey), "fixed-16")
        let stamp = try XCTUnwrap(record.extra.text(Scionic.timestampKey))
        XCTAssertEqual(stamp.count, 20, stamp)
        XCTAssertTrue(stamp.hasPrefix("20") && stamp.hasSuffix("Z"), stamp)
        // The folder on top is the same folder: only the record differs.
        XCTAssertEqual(record.top, try recordOf(plainStore, plain).top)
    }

    func testEveryEntryCanBeGivenExtraData() throws {
        let (temp, plainStore, plain) = try sampleTree("entry-extra")
        let folder = temp.join("sample")
        let store = MemoryStore()
        var seen: [String] = []
        let root = try build(store, path: folder, options: smallOptions()) { path, name, kind in
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, name)
            var isFolder: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), path)
            XCTAssertEqual(isFolder.boolValue, kind == .folder, path)
            seen.append(name)
            return try ExtraData().with("kind", text: kind == .folder ? "d" : "f")
        }
        XCTAssertNotEqual(root, plain)
        XCTAssertEqual(
            seen.sorted(),
            [
                "a.bin", "b.bin", "copy-of-model.bin", "data", "empty.bin", "exactly-two-chunks.bin",
                "model.bin", "nothing-here", "readme.txt", "shards", "weights",
            ]
        )
        XCTAssertEqual(try lookup(store, root, path: "weights/shards")?.extra.text("kind"), "d")
        let model = try XCTUnwrap(lookup(store, root, path: "weights/model.bin"))
        XCTAssertEqual(model.extra.text("kind"), "f")
        // Extra data sits beside the name: the file itself is the same file.
        XCTAssertEqual(model.hash, try lookup(plainStore, plain, path: "weights/model.bin")?.hash)
        _ = try verify(store, root)
    }

    func testAFileOnItsOwnIsATree() throws {
        let temp = try TempDir("top-file")
        let data = corpusBytes("alone", 70)
        let path = temp.join("whatever-it-is-called.bin")
        try writeFile(path, data)
        let store = MemoryStore()
        let root = try build(store, path: path, options: smallOptions())
        let summary = try verify(store, root)
        XCTAssertEqual(summary.record.top.kind, .file)
        XCTAssertEqual(summary.files, 1)
        XCTAssertEqual(summary.folders, 0)
        XCTAssertEqual(try readFile(store, summary.record.top), data)
        // The same bytes under another name are the same tree.
        let otherPath = temp.join("other-name")
        try writeFile(otherPath, data)
        XCTAssertEqual(try build(store, path: otherPath, options: smallOptions()), root)
        // An empty file is a tree too.
        let emptyPath = temp.join("empty")
        try writeFile(emptyPath, [])
        let empty = try build(store, path: emptyPath, options: smallOptions())
        let totals = try verify(store, empty).record.totals
        XCTAssertEqual([totals.chunks, totals.chunkBytes, totals.listBytes], [0, 0, 0])
    }

    func testALinkIsNeverFollowed() throws {
        let temp = try TempDir("links")
        let outside = temp.join("outside-secret.txt")
        try writeFile(outside, bytes("not part of the folder"))
        let folder = temp.join("folder")
        try writeFile(folder + "/inside.txt", bytes("part of the folder"))
        let link = folder + "/link.txt"
        do {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        } catch {
            // Windows lets only some accounts make links.
            throw XCTSkip("this account cannot make a link (\(error))")
        }

        let store = MemoryStore()
        expectError({ _ = try build(store, path: folder, options: smallOptions()) }) { error in
            guard case let .unsupportedEntry(path, what) = error else {
                return false
            }
            return slashed(path) == slashed(link) && what == "a link"
        }
        var options = smallOptions()
        options.links = .skip
        let root = try build(store, path: folder, options: options)
        XCTAssertNil(try lookup(store, root, path: "link.txt"))
        XCTAssertNotNil(try lookup(store, root, path: "inside.txt"))
        XCTAssertFalse(try store.has(.chunk, Hash.of(bytes("not part of the folder"))))
    }

    #if os(Windows)
    func testOnWindowsANameIsReadAsTheFolderListsIt() throws {
        // Windows drops a dot or a space from the end of a name when it looks a
        // path up, and takes `nul` for a device wherever it stands. So a file
        // `model.` beside a file `model` would be read as `model`. Such names are
        // made by a path that begins with `\\?\`, which is taken as it is.
        let temp = try TempDir("windows-names")
        defer { removeExact(temp.join("tree")) }
        let exact = try exactPath(temp.join("tree"))
        let files = ["model", "model.", "model ", "nul", "dir/inside", "dir./inside", ".../inside"]
        try makeFolderExact(exact + [0])
        for name in files {
            var path = exact
            let parts = name.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                path += [0x5C] + Array(part.utf16)
                try makeFolderExact(path + [0])
            }
            path += [0x5C] + Array(parts[parts.count - 1].utf16)
            try writeFileExact(path + [0], corpusBytes("names-\(name)", 16))
        }

        for workers in [1, 4] {
            let store = MemoryStore()
            let root = try build(store, path: temp.join("tree"), options: BuildOptions(chunking: smallChunks(), workers: workers))
            for name in files {
                let entry = try XCTUnwrap(lookup(store, root, path: name), name)
                XCTAssertEqual(try readFile(store, entry.target), corpusBytes("names-\(name)", 16), "\(name) with \(workers) workers")
            }
            // Windows cannot hold these names as they are, so here the tree is
            // not written out: nothing is made, and the error names the name.
            let out = temp.join("out-\(workers)")
            expectError({ try writeToDisk(store, root, to: out) }) { error in
                if case .unwritableName = error {
                    return true
                }
                return false
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out))
        }
    }
    #endif

    func testAFolderInside128OthersIsTooDeep() throws {
        // Made by hand: a path that long does not fit on every system.
        let store = MemoryStore()
        var builder = Builder(store: store, chunking: smallChunks())
        let file = try builder.file(bytes: bytes("at the bottom"))
        var inner = try builder.folder([Entry(name: "file", target: file)])
        for _ in 1..<128 {
            inner = try builder.folder([Entry(name: "d", target: inner)])
        }
        // 128 folders, one inside the other, is the most there can be.
        let root = try builder.finish(top: inner)
        XCTAssertEqual(try verify(store, root).folders, 128)

        builder = Builder(store: store, chunking: smallChunks())
        let oneMore = try builder.folder([Entry(name: "d", target: inner)])
        let recordsBefore = store.count(.record)
        expectError({ _ = try builder.finish(top: oneMore) }) { error in
            if case .tooDeep(128) = error {
                return true
            }
            return false
        }
        XCTAssertEqual(store.count(.record), recordsBefore, "no record is kept")

        // A folder that is reached twice is measured by its deepest place. Here
        // 100 folders sit one inside the other. The top reaches them directly,
        // under `near`, and again under `far`, with more folders on the way.
        func hundredDeep(_ wrapped: Int) throws -> Root {
            let builder = Builder(store: store, chunking: smallChunks())
            var hundred = try builder.folder([Entry(name: "file", target: file)])
            for _ in 1..<100 {
                hundred = try builder.folder([Entry(name: "d", target: hundred)])
            }
            var far = hundred
            for _ in 0..<wrapped {
                far = try builder.folder([Entry(name: "d", target: far)])
            }
            let top = try builder.folder([Entry(name: "far", target: far), Entry(name: "near", target: hundred)])
            return try builder.finish(top: top)
        }
        // The top, 27 folders, and the hundred: 128 on the longest way down.
        _ = try verify(store, try hundredDeep(27))
        // One more on the way, and the hundred sit too deep under `far`, though
        // they are well within the limit under `near`.
        expectError({ _ = try hundredDeep(28) }) { error in
            if case .tooDeep(128) = error {
                return true
            }
            return false
        }
    }

    func testTheTimeIsWrittenInUTCToTheSecond() {
        XCTAssertEqual(timestamp(0), "1970-01-01T00:00:00Z")
        XCTAssertEqual(timestamp(951_782_400), "2000-02-29T00:00:00Z")
        XCTAssertEqual(timestamp(1_794_472_200), "2026-11-12T08:30:00Z")
        XCTAssertEqual(timestamp(4_102_444_799), "2099-12-31T23:59:59Z")
        XCTAssertEqual(timestamp(-1), "1969-12-31T23:59:59Z")
    }
}
