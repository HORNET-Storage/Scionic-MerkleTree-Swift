// What the tests of syncing share: stores to compare, peers that a test can
// watch and change, and a connection inside one process that holds no more
// bytes than it is told to.

import Dispatch
import Foundation
@testable import ScionicMerkleTree

/// Everything a store holds, by kind and hash, for comparing two stores.
func contents(_ store: MemoryStore) throws -> [String] {
    var all: [String] = []
    for kind in Stored.allCases {
        for hash in store.hashes(kind).sorted() {
            all.append("\(kind) \(hash.hex) \(hexText(try store.get(kind, hash) ?? []))")
        }
    }
    return all
}

/// Whether two stores hold the same things.
func sameStores(_ left: MemoryStore, _ right: MemoryStore) throws -> Bool {
    try contents(left) == contents(right)
}

/// Bytes in memory, to read from. A source can give them in reads of awkward
/// lengths: one byte, then seven, then all that is asked for, again and again.
final class BytesSource: ByteSource {
    private let bytes: [UInt8]
    private var at = 0
    private let awkward: Bool

    init(_ bytes: [UInt8], awkward: Bool = false) {
        self.bytes = bytes
        self.awkward = awkward
    }

    var left: Int {
        bytes.count - at
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        var count = min(buffer.count, bytes.count - at)
        if awkward {
            count = min(count, [1, 7, buffer.count][(bytes.count - at) % 3])
        }
        bytes.withUnsafeBytes { raw in
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[at..<(at + count)]))
        }
        at += count
        return count
    }
}

/// Bytes written to memory. With `keepsBack`, nothing written shows until it is
/// flushed, as with a writer that keeps bytes back.
final class BytesSink: ByteSink {
    private(set) var bytes: [UInt8] = []
    private var kept: [UInt8] = []
    private let keepsBack: Bool
    /// How many bytes each write was given, and where it was flushed.
    private(set) var writes: [Int] = []
    private(set) var flushes = 0

    init(keepsBack: Bool = false) {
        self.keepsBack = keepsBack
    }

    func write(_ more: UnsafeRawBufferPointer) throws {
        writes.append(more.count)
        if keepsBack {
            kept.append(contentsOf: more)
        } else {
            bytes.append(contentsOf: more)
        }
    }

    func flush() throws {
        flushes += 1
        bytes.append(contentsOf: kept)
        kept.removeAll()
    }
}

/// What went over the wire to one peer: every request, the longest frame its
/// asker would take in answer, and every frame of every answer.
struct Wire {
    var requests: [[UInt8]] = []
    var limits: [Int] = []
    var frames: [[UInt8]] = []

    /// How many frames of one kind were sent.
    func framesOf(_ tag: UInt8) -> Int {
        frames.filter { $0.first == tag }.count
    }

    /// How many requests of one kind were asked.
    func requestsOf(_ tag: UInt8) -> Int {
        requests.filter { $0.first == tag }.count
    }
}

/// Refuses a frame that is longer than its asker takes, as a connection does
/// before it reads the frame.
func testWithin(_ limit: Int, _ frame: [UInt8]) throws {
    if frame.count > limit {
        throw ScionicError.limitExceeded(what: "a frame", limit: UInt64(limit), requested: UInt64(frame.count))
    }
}

/// A peer that answers from a store, as an honest one does, and lets a test see
/// and change what goes over the wire.
final class TestPeer: Peer {
    private let responder: Responder
    var wire = Wire()
    /// Changes the frames of an answer before the receiver sees them. It is
    /// given the request, and the frames the honest answer has.
    var tamper: (([UInt8], [[UInt8]]) -> [[UInt8]])?

    init(_ store: any Store, tamper: (([UInt8], [[UInt8]]) -> [[UInt8]])? = nil) {
        self.responder = Responder(store)
        self.tamper = tamper
    }

    func ask(_ request: [UInt8], limit: Int, onFrame: ([UInt8]) throws -> Void) throws {
        wire.requests.append(request)
        wire.limits.append(limit)
        var frames: [[UInt8]] = []
        try responder.answer(request) { frames.append($0) }
        if let tamper {
            frames = tamper(request, frames)
        }
        for frame in frames {
            wire.frames.append(frame)
            try testWithin(limit, frame)
            try onFrame(frame)
        }
    }
}

/// A peer that says whatever a test makes it say.
final class ScriptedPeer: Peer {
    private let script: ([UInt8]) -> [[UInt8]]

    init(_ script: @escaping ([UInt8]) -> [[UInt8]]) {
        self.script = script
    }

    func ask(_ request: [UInt8], limit: Int, onFrame: ([UInt8]) throws -> Void) throws {
        for frame in script(request) {
            try testWithin(limit, frame)
            try onFrame(frame)
        }
    }
}

/// How long one end of a pipe waits for the other before it gives up. Two ends
/// that wait for each other would wait for ever, and a test that hangs says
/// nothing.
let pipeWait: TimeInterval = 20

struct PipeStuck: Error, CustomStringConvertible {
    var description: String { "both ends of a pipe wait for each other" }
}

struct PipeClosed: Error, CustomStringConvertible {
    var description: String { "the other end of the pipe is gone" }
}

/// One direction of a connection, inside one process. It holds `capacity` bytes
/// and no more: a writer waits while it is full, as a writer to a real
/// connection does, and a reader waits while it is empty. One that holds
/// nothing hands a write over only as the other end reads it. Closing either
/// end ends the stream, once what is in the pipe is read.
final class Pipe: @unchecked Sendable {
    private let condition = NSCondition()
    private var held: [UInt8] = []
    private var start = 0
    private var closed = false
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    private var count: Int {
        held.count - start
    }

    private func waitFor(_ deadline: Date) throws {
        if !condition.wait(until: deadline) {
            throw PipeStuck()
        }
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The end that is read from.
    var reader: ByteSource {
        PipeReader(self)
    }

    /// The end that is written to.
    var writer: ByteSink {
        PipeWriter(self)
    }

    fileprivate func write(_ bytes: UnsafeRawBufferPointer) throws {
        let deadline = Date().addingTimeInterval(pipeWait)
        condition.lock()
        defer { condition.unlock() }
        if capacity == 0 {
            if closed {
                throw PipeClosed()
            }
            held.append(contentsOf: bytes)
            condition.broadcast()
            while count > 0 {
                if closed {
                    throw PipeClosed()
                }
                try waitFor(deadline)
            }
            return
        }
        var done = 0
        while done < bytes.count {
            while count >= capacity && !closed {
                try waitFor(deadline)
            }
            if closed {
                throw PipeClosed()
            }
            let more = min(bytes.count - done, capacity - count)
            held.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[done..<(done + more)]))
            done += more
            condition.broadcast()
        }
    }

    fileprivate func read(_ out: UnsafeMutableRawBufferPointer) throws -> Int {
        if out.isEmpty {
            return 0
        }
        let deadline = Date().addingTimeInterval(pipeWait)
        condition.lock()
        defer { condition.unlock() }
        while count == 0 {
            if closed {
                return 0
            }
            try waitFor(deadline)
        }
        let taken = min(out.count, count)
        held.withUnsafeBytes { raw in
            out.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[start..<(start + taken)]))
        }
        start += taken
        if start == held.count {
            held.removeAll(keepingCapacity: true)
            start = 0
        }
        condition.broadcast()
        return taken
    }
}

private final class PipeReader: ByteSource {
    let pipe: Pipe

    init(_ pipe: Pipe) {
        self.pipe = pipe
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try pipe.read(buffer)
    }
}

private final class PipeWriter: ByteSink {
    let pipe: Pipe

    init(_ pipe: Pipe) {
        self.pipe = pipe
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try pipe.write(bytes)
    }
}

/// What a client wrote: every write and every flush, and all of the bytes.
final class Flights: ByteSink {
    private let inner: ByteSink
    private var current = 0
    /// How many bytes went out between one flush and the next.
    private(set) var sizes: [Int] = []
    /// How many writes there were between one flush and the next.
    private(set) var writes: [Int] = []
    private var writesNow = 0
    private(set) var all: [UInt8] = []

    init(_ inner: ByteSink) {
        self.inner = inner
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try inner.write(bytes)
        current += bytes.count
        writesNow += 1
        all.append(contentsOf: bytes)
    }

    func flush() throws {
        sizes.append(current)
        writes.append(writesNow)
        current = 0
        writesNow = 0
    }
}

/// Serves `store` on a thread of its own, and runs `client` on this one, with a
/// connection between them that holds no more than it is given: so many bytes
/// on the way to the server, and so many on the way back.
///
/// It gives what the client gave, what the client sent, flight by flight, and
/// how the serving ended.
func connected<T>(
    _ store: any Store,
    toServer: Int,
    toClient: Int,
    serving: @escaping @Sendable (any Store, ByteSource, ByteSink) throws -> Void = { try serve($0, from: $1, to: $2) },
    _ client: (StreamPeer) throws -> T
) -> (asked: Result<T, any Error>, sent: Flights, served: (any Error)?) {
    let toServerPipe = Pipe(capacity: toServer)
    let toClientPipe = Pipe(capacity: toClient)
    let sent = Flights(toServerPipe.writer)
    let served = Shared<(any Error)?>(nil)
    let done = DispatchSemaphore(value: 0)
    let lent = Unchecked(store)
    Thread.detachNewThread {
        do {
            try serving(lent.value, toServerPipe.reader, toClientPipe.writer)
        } catch {
            served.with { $0 = error }
        }
        // The serving is over: nothing more comes, and nothing more is read.
        toClientPipe.close()
        toServerPipe.close()
        done.signal()
    }
    let asked = Result { try client(StreamPeer(input: toClientPipe.reader, output: sent)) }
    // The client hangs up, and the serving ends.
    toServerPipe.close()
    toClientPipe.close()
    done.wait()
    return (asked, sent, served.with { $0 })
}
