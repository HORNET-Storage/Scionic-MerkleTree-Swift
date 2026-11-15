// How long a builder's windows are: a file's windows grow once its store keeps
// its chunks more slowly than the file is read while helpers are free, and only
// then.

import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Chunks of a fixed 4 MiB: a window of a builder alone holds two, and one of a
/// builder with help eight.
private let chunk = 4 << 20

/// What one window of a builder alone holds.
private let alone = 8 << 20

/// A store that takes a while over each thing it keeps, as one that writes to a
/// disk does.
private final class SlowToKeep: Store, @unchecked Sendable {
    let inner = MemoryStore()

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        Thread.sleep(forTimeInterval: 0.1)
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// A store that counts the chunks it has kept.
private final class Counted: Store, @unchecked Sendable {
    let inner = MemoryStore()
    let chunks = Shared(0)

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        try inner.put(kind, hash, bytes)
        if kind == .chunk {
            chunks.with { $0 += 1 }
        }
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// A store that takes every helper that is free whenever it is handed something
/// to keep, as other files would.
private final class Taking: Store, @unchecked Sendable {
    let inner = MemoryStore()
    let helpers: Helpers

    init(_ helpers: Helpers) {
        self.helpers = helpers
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        _ = helpers.take(Int.max)
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// Builds a file of `chunks` chunks of 4 MiB, each of a byte of its own, with the
/// helpers `helpers` counts. `asked` is told where each read starts and how much
/// it asks for, before it is answered.
///
/// A builder's windows start short and double as a file fills them. So the first
/// two windows are read in several reads, and every later one in one read of all
/// the window holds, until a window grows: then in a read of 8 MiB, another of
/// 8 MiB, and one of 16 MiB.
private func readThrough(_ store: any Store, _ helpers: Helpers, chunks: Int, _ asked: (Int, Int) -> Void) throws {
    let chunking = try Chunking.fixed(UInt32(chunk))
    let builder = Builder(store: store, chunking: chunking, helpers: helpers)
    let length = chunks * chunk
    var at = 0
    _ = try builder.file { buffer in
        asked(at, buffer.count)
        let count = min(buffer.count, length - at)
        var done = 0
        while done < count {
            let index = (at + done) / chunk
            let end = min((index + 1) * chunk - at, count)
            memset(buffer.baseAddress! + done, Int32(index % 256), end - done)
            done = end
        }
        at += count
        return count
    }
}

final class WindowsTests: XCTestCase {
    func testAFileWhoseChunksAreKeptSlowlyIsReadInLongerWindowsOnceHelpersAreFree() throws {
        // The file starts while no helper is free, as one does that starts before
        // the threads with no file of their own give themselves up.
        let helpers = Helpers(free: 0)
        var longest = 0
        try readThrough(SlowToKeep(), helpers, chunks: 12) { at, length in
            if at == 0 {
                helpers.give(6)
            }
            longest = max(longest, length)
        }
        XCTAssertGreaterThan(longest, alone, "the longest read asked for \(longest) bytes")
    }

    func testAFileWhoseChunksAreKeptAsFastAsItIsReadKeepsItsShortWindows() throws {
        let store = Counted()
        let helpers = Helpers(free: 0)
        var longest = 0
        try readThrough(store, helpers, chunks: 12) { at, length in
            if at == 0 {
                helpers.give(6)
            }
            // A window is read only once the chunks before it are kept, and a
            // while after: the store keeps up with the file, however long hashing
            // takes here.
            let before = at / alone * (alone / chunk)
            let waited = Date()
            while store.chunks.with({ $0 }) < before && Date().timeIntervalSince(waited) < 10 {
                Thread.sleep(forTimeInterval: 0.001)
            }
            Thread.sleep(forTimeInterval: 0.02)
            longest = max(longest, length)
        }
        XCTAssertLessThanOrEqual(longest, alone, "a read asked for \(longest) bytes")
    }

    func testHelpersThatAreFreeForAMomentDoNotGrowAWindow() throws {
        let helpers = Helpers(free: 0)
        var held = 0
        var longestEarly = 0
        var longest = 0
        // Free while windows 1 to windowsBehindToGrow - 1 are read, taken by other
        // files while the next one is read, and free again from the one after:
        // the windows may grow only that many windows later, and a window that
        // has grown asks for more than a short one holds in its third read.
        let early = (2 * windowsBehindToGrow + 3) * alone
        try readThrough(SlowToKeep(), helpers, chunks: 20) { at, length in
            let window = at / alone
            if at == 0 {
                helpers.give(6)
            } else if window == windowsBehindToGrow {
                held += helpers.take(Int.max)
            } else if window == windowsBehindToGrow + 1 {
                helpers.give(held)
                held = 0
            }
            if at < early {
                longestEarly = max(longestEarly, length)
            }
            longest = max(longest, length)
        }
        XCTAssertLessThanOrEqual(longestEarly, alone, "a read before byte \(early) asked for \(longestEarly) bytes")
        XCTAssertGreaterThan(longest, alone, "the windows never grew")
    }

    func testAWindowThatTooFewHelpersCouldShareKeepsItsLength() throws {
        let helpers = Helpers(free: 0)
        var longest = 0
        // Each window takes two helpers for its two chunks, and leaves one.
        try readThrough(SlowToKeep(), helpers, chunks: 12) { at, length in
            if at == 0 {
                helpers.give(3)
            }
            longest = max(longest, length)
        }
        XCTAssertLessThanOrEqual(longest, alone, "a read asked for \(longest) bytes")
    }

    func testChunksThatNoHelperKeepsDoNotCountAsBehind() throws {
        let helpers = Helpers(free: 0)
        var longest = 0
        // No helper is free when a window's chunks are handed out, and six or more
        // are once the next window is read: this thread keeps every chunk itself,
        // after the read, and the store has kept none of them by then whatever its
        // speed.
        try readThrough(Taking(helpers), helpers, chunks: 12) { at, length in
            if at >= alone {
                helpers.give(6)
            }
            longest = max(longest, length)
        }
        XCTAssertLessThanOrEqual(longest, alone, "a read asked for \(longest) bytes")
    }
}
