// Stores and writers that fail, for the tests that hold the library to ending
// as they did: with nothing left waiting, and nothing left held open.

import Dispatch
import Foundation
import XCTest
@testable import ScionicMerkleTree

/// What a store that falls over throws. Swift cannot catch a crash, so a store
/// whose own code has a fault is one that throws where it never should.
struct FellOver: Error {}

/// A store that falls over whenever it is handed a chunk.
final class FallingOnPut: Store, @unchecked Sendable {
    let inner = MemoryStore()

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        if kind == .chunk {
            throw FellOver()
        }
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        try inner.get(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// A store that falls over whenever a chunk is asked for. It says what it holds
/// without falling over.
final class FallingOnGet: Store, @unchecked Sendable {
    let inner: any Store

    init(_ inner: any Store) {
        self.inner = inner
    }

    func put(_ kind: Stored, _ hash: Hash, _ bytes: UnsafeRawBufferPointer) throws {
        try inner.put(kind, hash, bytes)
    }

    func get(_ kind: Stored, _ hash: Hash) throws -> [UInt8]? {
        if kind == .chunk {
            throw FellOver()
        }
        return try inner.get(kind, hash)
    }

    func has(_ kind: Stored, _ hash: Hash) throws -> Bool {
        try inner.has(kind, hash)
    }

    func size(_ kind: Stored, _ hash: Hash) throws -> UInt64? {
        try inner.size(kind, hash)
    }

    func remove(_ kind: Stored, _ hash: Hash) throws {
        try inner.remove(kind, hash)
    }
}

/// A writer that fails once it is given more than it has room left for.
final class BrokenSink: ByteSink {
    struct Broken: Error {}

    private var left: Int

    init(left: Int) {
        self.left = left
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.count > left {
            left = 0
            throw Broken()
        }
        left -= bytes.count
    }
}

/// Runs `work` on a thread of its own, and gives how it ended. Work that has not
/// ended after 20 seconds fails the test, and gives nil.
func endsWithin<T>(
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: @escaping @Sendable () throws -> T
) -> Result<T, any Error>? {
    let outcome = Shared<Result<T, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        let result = Result { try work() }
        outcome.with { $0 = result }
        done.signal()
    }
    if done.wait(timeout: .now() + 20) == .timedOut {
        XCTFail("\(what): it was left waiting", file: file, line: line)
        return nil
    }
    return outcome.with { $0 }
}

/// Holds that work ended as its store did: by falling over.
func assertFell<T>(_ outcome: Result<T, any Error>?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    switch outcome {
    case nil:
        return // it was left waiting, and the test has failed for that
    case .success?:
        XCTFail("\(what): it ended, and it did not fall over as its store did", file: file, line: line)
    case let .failure(error)?:
        XCTAssertTrue(error is FellOver, "\(what) ended with \(error)", file: file, line: line)
    }
}

/// Gives a folder another name and its own again. Windows refuses that for a
/// folder that anything holds open, so this says that the work has let go of
/// everything.
func movable(_ folder: String) throws {
    try FileManager.default.moveItem(atPath: folder, toPath: folder + "-moved")
    try FileManager.default.moveItem(atPath: folder + "-moved", toPath: folder)
}
