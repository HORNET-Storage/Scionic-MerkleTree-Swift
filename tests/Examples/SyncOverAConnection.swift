import Foundation
import ScionicMerkleTree
import XCTest

/// The side that holds the tree. It answers one peer's requests until the
/// peer hangs up.
func serveOnePeer(_ store: any Store, over connection: any ByteSource & ByteSink) throws {
    try serve(store, from: connection, to: connection)
}

/// The side that wants the tree. A fetch that was cut off goes on from what
/// the store holds when it is run again.
func fetchTree(_ root: Root, into store: any Store, over connection: any ByteSource & ByteSink) throws {
    let peer = StreamPeer(input: connection, output: connection)
    _ = try fetch(store, root, from: peer)
}

/// One end of a connection inside this program: it reads what the other end
/// writes, and writes what the other end reads. Each way holds 64 KiB, as a
/// connection over a network holds some.
private final class End: ByteSource, ByteSink, @unchecked Sendable {
    private let incoming: Pipe
    private let outgoing: Pipe

    init(reading incoming: Pipe, writing outgoing: Pipe) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try incoming.reader.read(into: buffer)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try outgoing.writer.write(bytes)
    }

    /// Hangs up: the other end reads to the end of what was written.
    func close() {
        outgoing.close()
    }
}

/// How the serving ended, once it has.
private final class Served: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: (any Error)?
}

final class SyncOverAConnectionExample: XCTestCase {
    // Syncing runs over anything that reads and writes bytes. Here it is a
    // connection inside this program, with a thread at each end.
    func testSyncOverAConnection() throws {
        // The side that holds a tree. A single file can be a tree on its own.
        let publisher = MemoryStore()
        let builder = Builder(store: publisher, chunking: .fastCDCv1)
        let weights = try builder.file(bytes: [UInt8](repeating: 7, count: 3 << 20))
        let root = try builder.finish(top: weights)

        let toPublisher = Pipe(capacity: 64 << 10)
        let toMirror = Pipe(capacity: 64 << 10)
        let publisherEnd = End(reading: toPublisher, writing: toMirror)
        let mirrorEnd = End(reading: toMirror, writing: toPublisher)
        let served = Served()
        Thread.detachNewThread {
            do {
                try serveOnePeer(publisher, over: publisherEnd)
            } catch {
                served.error = error
            }
            publisherEnd.close()
            served.done.signal()
        }

        // The side that wants the tree. Once it has it, it hangs up, and the
        // serving ends.
        let mirror = MemoryStore()
        let fetched = Result { try fetchTree(root, into: mirror, over: mirrorEnd) }
        mirrorEnd.close()
        XCTAssertEqual(served.done.wait(timeout: .now() + 20), .success, "the serving was left waiting")
        try fetched.get()
        XCTAssertNil(served.error)
        XCTAssertEqual(mirror.bytes(.chunk), 3 << 20, "bytes of chunks arrived")
        XCTAssertNoThrow(try verify(mirror, root))
    }
}
