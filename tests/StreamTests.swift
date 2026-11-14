// Syncing over a connection: requests one way, answers the other.

import XCTest
@testable import ScionicMerkleTree

/// Bytes with their length before them, as a frame or a request goes on a
/// connection.
private func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
    u32be(UInt32(bytes.count)) + bytes
}

/// A tree whose fetch asks for many lists in one round.
func manySmallFiles(_ count: Int) throws -> (store: MemoryStore, root: Root) {
    let store = MemoryStore()
    let builder = Builder(store: store, chunking: smallChunks())
    let entries = try (0..<count).map { index in
        try Entry(name: "f\(padded(index, 3))", target: builder.file(bytes: corpusBytes("small-\(index)", 20)))
    }
    return (store, try builder.finish(top: builder.folder(entries)))
}

/// Answers requests as `serve` does, but reads one request at a time and nothing
/// ahead of it: an answerer of another make.
@Sendable
func answerOneAtATime(_ store: any Store, _ input: ByteSource, _ output: ByteSink) throws {
    let responder = Responder(store)
    while let request = try readFrame(input, limit: Scionic.maxRequestBytes) {
        try responder.answer(request) { try writeFrame(output, $0) }
        try writeEnd(output)
        try output.flush()
    }
}

/// A writer that takes every write and cannot be flushed.
private final class Unflushable: ByteSink {
    struct Broken: Error {}

    func write(_ bytes: UnsafeRawBufferPointer) throws {}

    func flush() throws {
        throw Broken()
    }
}

final class StreamTests: XCTestCase {
    func testATreeIsFetchedOverAConnection() throws {
        let (_, source, root) = try sampleTree("stream-fetch")
        // A connection that holds next to nothing on the way back, so that the
        // server waits on every answer until the client reads it, and one with
        // room to spare.
        for (toServer, toClient) in [(Scionic.requestsAheadBytes, 1), (Scionic.requestsAheadBytes, 100), (1 << 20, 1 << 20)] {
            let dest = MemoryStore()
            let (summary, _, served) = connected(source, toServer: toServer, toClient: toClient) { peer in
                try fetch(dest, root, from: peer)
            }
            XCTAssertNil(served)
            XCTAssertEqual(try summary.get(), try verify(dest, root))
            XCTAssertEqual(try contents(dest), try contents(source))
        }
    }

    func testPartsOfATreeAreReadOverAConnection() throws {
        let (_, source, root) = try sampleTree("stream-parts")
        let content = corpusBytes("model", 1_000)
        let (asked, _, served) = connected(source, toServer: Scionic.requestsAheadBytes, toClient: 7) { peer in
            let remote = try Remote(peer: peer, root: root)
            XCTAssertEqual(remote.record, try recordOf(source, root))
            let model = try XCTUnwrap(remote.lookup("weights/model.bin"))
            XCTAssertEqual(model, try lookup(source, root, path: "weights/model.bin"))
            XCTAssertNil(try remote.lookup("weights/absent"))
            let out = BytesSink()
            try remote.read(model.target, offset: 100, length: 333, to: out)
            XCTAssertEqual(out.bytes, Array(content[100..<433]))
            XCTAssertEqual(try remote.have(model.target).held, 63)
            let weights = try XCTUnwrap(remote.lookup("weights"))
            XCTAssertEqual(try remote.entries(weights.target, start: 0, count: 10).total, 3)
        }
        try asked.get()
        XCTAssertNil(served)
    }

    func testRequestsAreSentAheadOfTheirAnswersAndNeverTooFar() throws {
        // A folder of 150 small files: more lists than one round asks for, and
        // more requests in a round than are sent ahead at once.
        let source = MemoryStore()
        let builder = Builder(store: source, chunking: smallChunks())
        let entries = try (0..<150).map { index in
            try Entry(name: "f\(padded(index, 3))", target: builder.file(bytes: corpusBytes("file-\(index)", 20)))
        }
        let root = try builder.finish(top: builder.folder(entries))

        // The connection holds on the way to the server exactly what a client may
        // send ahead, and on the way back one byte. A client that sent further
        // ahead would wait for the server, which waits for the client.
        let dest = MemoryStore()
        let (summary, sent, served) = connected(source, toServer: Scionic.requestsAheadBytes, toClient: 1) { peer in
            try fetch(dest, root, from: peer)
        }
        XCTAssertNil(served)
        _ = try summary.get()
        XCTAssertEqual(try contents(dest), try contents(source))

        // 1 record, 1 folder, 150 lists and 150 requests for chunks.
        let flights = sent.sizes
        XCTAssertEqual(flights.reduce(0, +), (33 + 4) * 152 + (45 + 4) * 150)
        XCTAssertTrue(flights.allSatisfy { $0 <= Scionic.requestsAheadBytes }, "\(flights)")
        // 64 requests for lists take 2,368 bytes, so a round goes out in two
        // flights, and the first holds as many requests as fit.
        XCTAssertTrue(flights.contains(55 * 37), "\(flights)")
        XCTAssertLessThan(flights.count, 30, "\(flights)")
    }

    func testAnAnswerIsItsFramesAndThenALengthOfZero() throws {
        let (_, source, root) = try sampleTree("stream-bytes")
        let record = try recordOf(source, root).encode()
        let unknown = Root.of(record: bytes("nobody holds this"))
        /// Serves requests that are all there already, and gives what was answered.
        func served(_ requests: [UInt8]) -> (result: Result<Void, any Error>, answers: [UInt8]) {
            let answers = BytesSink()
            let result = Result { try serve(source, from: BytesSource(requests), to: answers) }
            return (result, answers.bytes)
        }

        // Nothing asked, nothing answered.
        var (result, answers) = served([])
        try result.get()
        XCTAssertTrue(answers.isEmpty)

        // Two requests: one for a record that is held, and one for a record that is
        // not.
        (result, answers) = served(lengthPrefixed(Request.record(root).encode()) + lengthPrefixed(Request.record(unknown).encode()))
        try result.get()
        XCTAssertEqual(answers, lengthPrefixed(record) + [0, 0, 0, 0] + lengthPrefixed([0x27, 1]) + [0, 0, 0, 0])

        // A request that is malformed ends the serving, and so does one that is
        // empty, one that is too long, and one that the stream ends inside.
        let tooLong = [UInt8](repeating: 0x33, count: Scionic.maxRequestBytes + 1)
        let bad: [[UInt8]] = [
            lengthPrefixed([0x3A, 1, 2]),
            lengthPrefixed([UInt8](repeating: 0x30, count: 32)),
            lengthPrefixed([]),
            lengthPrefixed(tooLong),
            Array(lengthPrefixed(Request.record(root).encode()).prefix(20)),
        ]
        for requests in bad {
            (result, answers) = served(requests)
            XCTAssertNotNil(failure(result), "\(requests.prefix(8))")
            XCTAssertTrue(answers.isEmpty)
        }
        // What came before it is answered.
        (result, answers) = served(lengthPrefixed(Request.record(root).encode()) + lengthPrefixed([0x3A]))
        XCTAssertEqual(failure(result)?.caseName, "invalidData")
        XCTAssertEqual(answers, lengthPrefixed(record) + [0, 0, 0, 0])
    }

    func testAConnectionThatAnAnswerLeftHalfReadIsNotUsedAgain() throws {
        let (_, source, root) = try sampleTree("stream-broken")
        let request = Request.record(root).encode()

        // An answer that is longer than its asker takes is refused by its length.
        // Its bytes are still on the connection, unread.
        var (asked, _, _) = connected(source, toServer: 4096, toClient: 4096) { peer in
            [
                Result { try peer.ask(request, limit: 10) { _ in } },
                Result { try peer.ask(request, limit: Scionic.maxRecordBytes) { _ in } },
            ]
        }
        var results = try asked.get()
        XCTAssertEqual(failure(results[0])?.caseName, "limitExceeded")
        XCTAssertEqual(failure(results[1])?.caseName, "peer")

        // The same when the asker refuses a frame for what is in it.
        (asked, _, _) = connected(source, toServer: 4096, toClient: 4096) { peer in
            [
                Result { try peer.ask(request, limit: Scionic.maxRecordBytes) { _ in throw ScionicError.intakeFailed } },
                Result { try peer.ask(request, limit: Scionic.maxRecordBytes) { _ in } },
            ]
        }
        results = try asked.get()
        XCTAssertEqual(failure(results[0])?.caseName, "intakeFailed")
        XCTAssertEqual(failure(results[1])?.caseName, "peer")

        // A connection whose answers were all read to their end is used again.
        let (frames, _, served) = connected(source, toServer: 4096, toClient: 4096) { peer in
            var frames = 0
            for _ in 0..<3 {
                try peer.ask(request, limit: Scionic.maxRecordBytes) { _ in frames += 1 }
            }
            return frames
        }
        XCTAssertNil(served)
        XCTAssertEqual(try frames.get(), 3)
    }

    // Connections as a program meets them: ones that hold nothing and hand a
    // write over only as the other end reads it, read and written as they are or
    // through buffers.

    func testTwoEndsNeverWaitForEachOtherOnAConnectionThatHoldsNothing() throws {
        // A round of this tree's fetch asks for 60 lists, and they are sent ahead
        // of their answers, 55 of them at once.
        let (source, root) = try manySmallFiles(60)
        for buffered in [false, true] {
            let dest = MemoryStore()
            let (fetched, _, served) = connected(source, toServer: 0, toClient: 0, buffered: buffered) { peer in
                try fetch(dest, root, from: peer)
            }
            XCTAssertNil(served, "buffered: \(buffered)")
            XCTAssertNoThrow(try fetched.get(), "buffered: \(buffered)")
            XCTAssertEqual(try contents(dest), try contents(source), "buffered: \(buffered)")
        }
    }

    func testRequestsCanBeSentOneAtATime() throws {
        let (source, root) = try manySmallFiles(60)
        // An answerer that reads one request at a time, on a connection that holds
        // nothing: no request may be sent ahead of an answer.
        let dest = MemoryStore()
        let (fetched, _, served) = connected(source, toServer: 0, toClient: 0, ahead: 0, serving: answerOneAtATime) { peer in
            try fetch(dest, root, from: peer)
        }
        XCTAssertNil(served)
        XCTAssertNoThrow(try fetched.get())
        XCTAssertEqual(try contents(dest), try contents(source))

        // What is set is held to what the format allows, at both ends.
        func longestFlight(_ ahead: Int) throws -> Int {
            let dest = MemoryStore()
            let (fetched, sent, served) = connected(source, toServer: Scionic.requestsAheadBytes, toClient: 1, ahead: ahead) { peer in
                try fetch(dest, root, from: peer)
            }
            XCTAssertNil(served, "\(ahead) bytes ahead")
            _ = try fetched.get()
            XCTAssertEqual(try contents(dest), try contents(source), "\(ahead) bytes ahead")
            return sent.sizes.max() ?? 0
        }
        // A request for a list takes 37 bytes, and one for chunks 49.
        XCTAssertEqual(try longestFlight(0), 49, "with nothing sent ahead")
        XCTAssertEqual(try longestFlight(-1), 49, "with less than nothing sent ahead")
        let hundred = try longestFlight(100)
        XCTAssertTrue((74...100).contains(hundred), "with 100 bytes sent ahead, \(hundred) went out at once")
        let all = try longestFlight(1 << 30)
        XCTAssertTrue(((Scionic.requestsAheadBytes - 49)...Scionic.requestsAheadBytes).contains(all), "\(all)")
    }

    func testARequestThatNoAnswererTakesIsNotSent() throws {
        let (_, source, root) = try sampleTree("stream-refused")
        let good = Request.record(root).encode()
        let (asked, sent, served) = connected(source, toServer: Scionic.requestsAheadBytes, toClient: 1 << 20) { peer in
            [
                Result { try peer.ask([], limit: Scionic.maxRecordBytes) { _ in } },
                Result { try peer.ask([UInt8](repeating: 0, count: Scionic.maxRequestBytes + 1), limit: Scionic.maxRecordBytes) { _ in } },
                // One that is refused among good ones: none of them is sent.
                Result {
                    try peer.askAll([
                        Asked(request: good, limit: Scionic.maxRecordBytes),
                        Asked(request: [], limit: 1),
                        Asked(request: good, limit: Scionic.maxRecordBytes),
                    ]) { _, _ in }
                },
                // And the connection is as good as it was.
                Result { try peer.ask(good, limit: Scionic.maxRecordBytes) { _ in } },
            ]
        }
        XCTAssertNil(served)
        let results = try asked.get()
        XCTAssertEqual(failure(results[0])?.caseName, "invalidData")
        XCTAssertEqual(failure(results[1])?.caseName, "limitExceeded")
        XCTAssertEqual(failure(results[2])?.caseName, "invalidData")
        XCTAssertNoThrow(try results[3].get())
        XCTAssertEqual(sent.all.count, good.count + 4)
    }

    func testABundleThatIsWrittenThroughABufferIsWrittenWhole() throws {
        let (_, source, root) = try sampleTree("stream-bundle-kept")
        // A writer that keeps everything back until it is flushed.
        let written = BytesSink(keepsBack: true)
        try exportBundle(source, root, to: written)
        let dest = MemoryStore()
        try importBundle(dest, root, from: BytesSource(written.bytes))
        XCTAssertEqual(try contents(dest), try contents(source))
        // And a writer that cannot be flushed is told.
        if case let .stream(_, failure)? = assertFails(try exportBundle(source, root, to: Unflushable()), "stream") {
            XCTAssertTrue(failure is Unflushable.Broken, "\(failure)")
        }
    }
}
