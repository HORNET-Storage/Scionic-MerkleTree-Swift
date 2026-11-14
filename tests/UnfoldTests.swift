// A tree keeps a folder once, however many places the folder has in it. So a
// small tree can stand for a very large one, and whatever goes through a tree
// place by place has to know when to stop.
//
// Checking a tree, taking it in and sending it go through each folder once, and
// need no such care. Writing a tree out is in ReadTests. Listing what changed
// between two trees is here.

import Foundation
import XCTest
@testable import ScionicMerkleTree

/// A folder with one file, under `levels` folders that each hold the one below
/// under two names.
private func doubled(_ builder: Builder, _ content: [UInt8], _ levels: Int) throws -> Target {
    let file = try builder.file(bytes: content)
    var folder = try builder.folder([Entry(name: "x", target: file)])
    for _ in 0..<levels {
        folder = try builder.folder([Entry(name: "a", target: folder), Entry(name: "b", target: folder)])
    }
    return folder
}

final class UnfoldTests: XCTestCase {
    func testTwoSmallTreesThatDifferAtMorePlacesThanAListHoldsAreRefused() throws {
        let store = MemoryStore()
        func finish(_ top: Target) throws -> Root {
            try Builder(store: store, chunking: smallChunks()).finish(top: top)
        }
        // Two trees of 41 small folders each. They differ in one file, and that
        // file has 2^40 places.
        var builder = Builder(store: store, chunking: smallChunks())
        let (oldTop, newTop) = (try doubled(builder, bytes("old"), 40), try doubled(builder, bytes("new"), 40))
        XCTAssertEqual(store.count(.folderList), 82)
        var (old, new) = (try finish(oldTop), try finish(newTop))
        // The search stops soon after it has found more than it may list.
        if case let .limitExceeded(_, limit, requested)? = assertFails(try diff(store, old: old, new: new, most: 10_000), "limitExceeded") {
            XCTAssertEqual(limit, 10_000)
            XCTAssertTrue(requested > limit && requested < limit + 1_000, "\(requested)")
        }
        // Left to itself, it lists a million changes and no more.
        XCTAssertEqual(Scionic.defaultMaxChanges, 1_000_000)
        XCTAssertEqual(try diff(store, old: old, new: old), [])

        // Ten levels of it are 1,024 places, and are listed.
        builder = Builder(store: store, chunking: smallChunks())
        (old, new) = (try finish(doubled(builder, bytes("old"), 10)), try finish(doubled(builder, bytes("new"), 10)))
        let changes = try diff(store, old: old, new: new)
        XCTAssertEqual(changes.count, 1_024)
        XCTAssertEqual(changes.first?.path, "a/a/a/a/a/a/a/a/a/a/x")
        XCTAssertEqual(changes.last?.path, "b/b/b/b/b/b/b/b/b/b/x")
        XCTAssertEqual(try diff(store, old: old, new: new, most: 1_024), changes)
        assertFails(try diff(store, old: old, new: new, most: 1_023), "limitExceeded")
    }

    func testALimitOnChangesIsHeldExactly() throws {
        let temp = try TempDir("unfold-exact")
        let folder = try sampleFolder(temp.path, "sample")
        let store = MemoryStore()
        let old = try build(store, path: folder, options: smallOptions())
        try FileManager.default.removeItem(atPath: folder + "/readme.txt")
        try writeFile(folder + "/weights/new.bin", bytes("new"))
        try writeFile(folder + "/data/new.bin", bytes("new"))
        let new = try build(store, path: folder, options: smallOptions())
        XCTAssertEqual(try diff(store, old: old, new: new).count, 3)
        XCTAssertEqual(try diff(store, old: old, new: new, most: 3).count, 3)
        for most in 0..<3 {
            assertFails(try diff(store, old: old, new: new, most: most), "limitExceeded", "\(most)")
        }
    }
}
