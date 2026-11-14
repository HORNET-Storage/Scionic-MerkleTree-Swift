// What changed between two trees.

import Foundation
import XCTest
@testable import ScionicMerkleTree

final class DiffTests: XCTestCase {
    func testEachChangeIsListedOnceByItsPath() throws {
        let temp = try TempDir("diff")
        let folder = try sampleFolder(temp.path, "sample")
        let store = MemoryStore()
        let old = try build(store, path: folder, options: smallOptions())
        XCTAssertEqual(try diff(store, old: old, new: old), [])

        // One chunk of a file changes.
        var model = corpusBytes("model", 1_000)
        model.replaceSubrange(320..<336, with: corpusBytes("changed", 16))
        try writeFile(folder + "/weights/model.bin", model)
        // A file gets another name.
        try FileManager.default.moveItem(atPath: folder + "/readme.txt", toPath: folder + "/notes.txt")
        // A folder comes, with two files in it, and a folder goes.
        try writeFile(folder + "/more/one.bin", corpusBytes("one", 40))
        try writeFile(folder + "/more/two.bin", corpusBytes("two", 40))
        try FileManager.default.removeItem(atPath: folder + "/data")
        // A file becomes a folder of the same name.
        try FileManager.default.removeItem(atPath: folder + "/empty.bin")
        try writeFile(folder + "/empty.bin/inside", bytes("no longer empty"))
        let new = try build(store, path: folder, options: smallOptions())

        let changes = try diff(store, old: old, new: new)
        let listed = changes.map { change -> String in
            switch change {
            case .added: return "\(change.path) added"
            case .removed: return "\(change.path) removed"
            case .changed: return "\(change.path) changed"
            }
        }
        XCTAssertEqual(listed, [
            "data removed",
            "empty.bin removed",
            "empty.bin added",
            "more added",
            "notes.txt added",
            "readme.txt removed",
            "weights/model.bin changed",
        ])
        for change in changes {
            switch change {
            case let .added(path, entry):
                XCTAssertEqual(try lookup(store, new, path: path), entry)
            case let .removed(path, entry):
                XCTAssertEqual(try lookup(store, old, path: path), entry)
            case let .changed(path, was, now):
                XCTAssertEqual(try lookup(store, old, path: path), was)
                XCTAssertEqual(try lookup(store, new, path: path), now)
                XCTAssertNotEqual(was.hash, now.hash)
                XCTAssertEqual(was.kind, .file)
                XCTAssertEqual([was.size, now.size], [1_000, 1_000])
            }
        }
        // The file that got another name is the same file.
        guard case let .added(_, notes) = changes[4], case let .removed(_, readme) = changes[5] else {
            return XCTFail("not the rename")
        }
        XCTAssertEqual(notes.target, readme.target)

        // The other way round, what was added is removed.
        let back = try diff(store, old: new, new: old)
        XCTAssertEqual(back.count, changes.count)
        if case let .removed(path, _) = back[3] {
            XCTAssertEqual(path, "more")
        } else {
            XCTFail("\(back[3])")
        }

        // What is the same in both trees is not read: the comparison works without
        // the folder that did not change, and without any file.
        let shards = try XCTUnwrap(lookup(store, new, path: "weights/shards"))
        try store.remove(.folderList, shards.hash)
        for hash in store.hashes(.fileList) {
            try store.remove(.fileList, hash)
        }
        for hash in store.hashes(.chunk) {
            try store.remove(.chunk, hash)
        }
        XCTAssertEqual(try diff(store, old: old, new: new), changes)
        // A folder that did change is needed.
        let weights = try XCTUnwrap(lookup(store, new, path: "weights"))
        try store.remove(.folderList, weights.hash)
        assertFails(try diff(store, old: old, new: new), "missing")
    }

    func testExtraDataThatChangedIsAChange() throws {
        let temp = try TempDir("diff-extra")
        let folder = try sampleFolder(temp.path, "sample")
        let store = MemoryStore()
        func tagged(_ tag: String) throws -> Root {
            try build(store, path: folder, options: smallOptions()) { _, name, _ in
                name == "weights" || name == "readme.txt" ? try ExtraData().with("tag", text: tag) : ExtraData()
            }
        }
        let (old, new) = (try tagged("one"), try tagged("two"))
        XCTAssertNotEqual(old, new)
        let changes = try diff(store, old: old, new: new)
        XCTAssertEqual(changes.map(\.path), ["readme.txt", "weights"])
        for change in changes {
            guard case let .changed(_, was, now) = change else {
                XCTFail("\(change)")
                continue
            }
            // The thing itself is the same. What is said about it differs.
            XCTAssertEqual(was.target, now.target)
            XCTAssertEqual(was.extra.text("tag"), "one")
            XCTAssertEqual(now.extra.text("tag"), "two")
        }
    }

    func testTreesWithAFileOnTopHaveNoEntriesToCompare() throws {
        let store = MemoryStore()
        let builder = Builder(store: store, chunking: smallChunks())
        let one = try builder.file(bytes: bytes("one"))
        let two = try builder.file(bytes: bytes("two"))
        let folder = try builder.folder([])
        func finish(_ top: Target, _ extra: ExtraData = ExtraData()) throws -> Root {
            try Builder(store: store, chunking: smallChunks()).finish(top: top, extra: extra)
        }
        let (first, second, empty) = (try finish(one), try finish(two), try finish(folder))
        // The same file under two records is the same tree to compare.
        let firstAgain = try finish(one, ExtraData().with("name", text: "again"))
        XCTAssertNotEqual(first, firstAgain)
        XCTAssertEqual(try diff(store, old: first, new: firstAgain), [])
        assertFails(try diff(store, old: first, new: second))
        assertFails(try diff(store, old: first, new: empty))
        assertFails(try diff(store, old: empty, new: second))
        XCTAssertEqual(try diff(store, old: empty, new: empty), [])
    }
}
