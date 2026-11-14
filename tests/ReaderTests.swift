// A file, a stream of frames and a bundle are the same however their source
// hands them over. A source that fails has failed: it is never taken for a
// shorter file or a shorter stream. And a source that miscounts its own bytes is
// an error, never a crash.
//
// A source either gives a count or throws, and a count of 0 is its end. So a
// source cannot give bytes and an error at once, or say that it has nothing yet,
// as a reader can in some languages.

import XCTest
@testable import ScionicMerkleTree

/// What a source that fails throws.
private struct Lost: Error {}

/// A source that hands its bytes over at a pace: for a read of so many bytes,
/// it gives what `pace` says, and never more than it has.
private final class PacedSource: ByteSource {
    private let bytes: [UInt8]
    private var at = 0
    private let pace: (Int) -> Int

    init(_ bytes: [UInt8], _ pace: @escaping (Int) -> Int) {
        self.bytes = bytes
        self.pace = pace
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = min(pace(buffer.count), buffer.count, bytes.count - at)
        bytes.withUnsafeBytes { raw in
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[at..<(at + count)]))
        }
        at += count
        return count
    }
}

/// One thing a scripted source does: it gives these bytes, over as many reads as
/// they take, and then, if it has one, throws this error.
private struct Step {
    var give: [UInt8] = []
    var fail: (any Error)?
}

/// A source that does its steps one after another, and then says that it has
/// ended.
private final class ScriptedSource: ByteSource {
    private let steps: [Step]
    private var step = 0
    private var at = 0
    private(set) var calls = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        calls += 1
        while step < steps.count {
            let current = steps[step]
            if at < current.give.count {
                let count = min(buffer.count, current.give.count - at)
                current.give.withUnsafeBytes { raw in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[at..<(at + count)]))
                }
                at += count
                return count
            }
            step += 1
            at = 0
            if let fail = current.fail {
                throw fail
            }
        }
        return 0
    }
}

/// A source that says it gave a count of bytes it cannot have given.
private final class Miscounting: ByteSource {
    private let count: (Int) -> Int

    init(_ count: @escaping (Int) -> Int) {
        self.count = count
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        count(buffer.count)
    }
}

/// A stream, handed over in each of the ways a source may hand it over.
private func manners(_ bytes: [UInt8], byteAtATime: Bool = true) -> [(String, () -> any ByteSource)] {
    var all: [(String, () -> any ByteSource)] = [
        ("all at once", { PacedSource(bytes) { $0 } }),
        ("half of what is asked for", { PacedSource(bytes) { max(1, $0 / 2) } }),
        ("one byte, then seven, then all that is asked for", { BytesSource(bytes, awkward: true) }),
        ("its last byte alone", { ScriptedSource([Step(give: Array(bytes.dropLast())), Step(give: Array(bytes.suffix(1)))]) }),
    ]
    if byteAtATime {
        all.append(("a byte at a time", { PacedSource(bytes) { _ in 1 } }))
    }
    return all
}

/// Holds that `error` is a stream's failure, with what the source threw in it.
private func assertLost(_ error: ScionicError?, _ what: String, operation: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
    guard case let .stream(told, failure)? = error else {
        return XCTFail("\(what): \(String(describing: error))", file: file, line: line)
    }
    XCTAssertTrue(failure is Lost, "\(what): \(failure)", file: file, line: line)
    if let operation {
        XCTAssertEqual(told, operation, what, file: file, line: line)
    }
}

final class ReaderTests: XCTestCase {
    func testAFileIsTheSameHoweverItsSourceHandsItOver() throws {
        for chunking in [smallChunks(), Chunking.fastCDCv1] {
            let byContent = chunking == .fastCDCv1
            let data = byContent ? corpusBytes("readers-by-content", 5 << 20) : corpusBytes("readers", 100_000)
            let want = try Builder(store: MemoryStore(), chunking: chunking).file(bytes: data)
            for (what, open) in manners(data, byteAtATime: !byContent) {
                let store = MemoryStore()
                let got = try Builder(store: store, chunking: chunking).file(from: open())
                XCTAssertEqual(got, want, "\(chunking.tag), \(what)")
                XCTAssertEqual(try readFile(store, got), data, "\(chunking.tag), \(what)")
            }
        }
        // A source that has ended is not asked again.
        let once = ScriptedSource([Step(give: bytes("the whole file"))])
        _ = try Builder(store: MemoryStore(), chunking: smallChunks()).file(from: once)
        XCTAssertEqual(once.calls, 2, "one read for the bytes, and one that tells the end")
    }

    func testASourceThatFailsIsNeverTakenForAShorterFile() throws {
        let data = corpusBytes("readers-failing", 1_000)
        let cases: [(String, [Step])] = [
            ("after its first bytes", [Step(give: Array(data[..<500]), fail: Lost())]),
            ("after later bytes", [Step(give: Array(data[..<300])), Step(give: Array(data[300..<600]), fail: Lost())]),
            ("before any byte", [Step(fail: Lost())]),
            ("after one chunk exactly", [Step(give: Array(data[..<16]), fail: Lost())]),
            ("after all of its bytes", [Step(give: data, fail: Lost())]),
        ]
        for (what, steps) in cases {
            let store = MemoryStore()
            let error = assertFails(try Builder(store: store, chunking: smallChunks()).file(from: ScriptedSource(steps)), "stream", what)
            assertLost(error, what, operation: "read a file's bytes")
            // A file that was not read to its end has no list.
            XCTAssertEqual(store.count(.fileList), 0, "\(what): a file was kept")
        }
    }

    func testASourceThatMiscountsIsAnErrorAndNeverACrash() throws {
        let (_, store, root) = try sampleTree("readers-miscount")
        let liars: [(String, () -> Miscounting)] = [
            ("more than it was asked for", { Miscounting { $0 + 1 } }),
            ("less than nothing", { Miscounting { _ in -1 } }),
        ]
        for (what, liar) in liars {
            assertFails(try readFrame(liar(), limit: 16), "invariant", "a frame, \(what)")
            assertFails(try Builder(store: MemoryStore(), chunking: smallChunks()).file(from: liar()), "invariant", "a file, \(what)")
            assertFails(try Builder(store: MemoryStore(), chunking: .fastCDCv1).file(from: liar()), "invariant", "a file, \(what)")
            assertFails(try importBundle(MemoryStore(), root, from: liar()), "invariant", "a bundle, \(what)")
            assertFails(try serve(store, from: liar(), to: BytesSink()), "invariant", "serving, \(what)")
            let peer = StreamPeer(input: liar(), output: BytesSink())
            assertFails(try Remote(peer: peer, root: root), "invariant", "a peer, \(what)")
        }
    }

    func testFramesComeOffAStreamHoweverItHandsThemOver() throws {
        let frames: [[UInt8]] = [bytes("one"), corpusBytes("stream-frame", 3_000), bytes("three")]
        let stream = BytesSink()
        for frame in frames {
            try writeFrame(stream, frame)
        }
        for (what, open) in manners(stream.bytes) {
            // One source for the whole stream, asked frame after frame.
            let input = open()
            for (at, want) in frames.enumerated() {
                XCTAssertEqual(try readFrame(input, limit: 4096), want, "\(what): frame \(at)")
            }
            XCTAssertNil(try readFrame(input, limit: 4096), "\(what): the end of the stream")
            // And asked once more, it has still ended.
            XCTAssertNil(try readFrame(input, limit: 4096), "\(what): the end of the stream, asked again")
        }
    }

    func testAStreamThatFailsHasFailedWhereverItFails() throws {
        let stream = BytesSink()
        try writeFrame(stream, bytes("one"))
        try writeFrame(stream, bytes("three"))
        let written = stream.bytes
        XCTAssertEqual(written.count, 16)
        // The stream fails after the bytes up to each place in turn: before the
        // first byte, inside a length, inside a frame, after a frame's last byte,
        // and after the last byte of all.
        for cut in 0...written.count {
            let input = ScriptedSource([Step(give: Array(written[..<cut]), fail: Lost())])
            var read: [[UInt8]] = []
            var error: ScionicError?
            while error == nil {
                do {
                    guard let frame = try readFrame(input, limit: 16) else {
                        XCTFail("a stream that fails after \(cut) bytes was taken to have ended")
                        break
                    }
                    read.append(frame)
                } catch let failed as ScionicError {
                    error = failed
                }
            }
            assertLost(error, "after \(cut) bytes", operation: "read a frame")
            // A frame that came whole before the failure is a frame. One that the
            // stream failed inside is not.
            XCTAssertEqual(read.count, (cut >= 7 ? 1 : 0) + (cut >= 16 ? 1 : 0), "after \(cut) bytes")
        }
    }

    func testABundleIsTakenInHoweverItIsHandedOverAndNeverWhenItsStreamFails() throws {
        let (_, source, root) = try sampleTree("readers-bundle")
        let bundle = BytesSink()
        try exportBundle(source, root, to: bundle)
        let written = bundle.bytes
        for (what, open) in manners(written) {
            let dest = MemoryStore()
            XCTAssertNoThrow(try importBundle(dest, root, from: open()), what)
            XCTAssertEqual(try contents(dest), try contents(source), what)
        }
        // The stream fails after the bytes up to each of many places, the last
        // byte of the bundle among them. A stream that failed is no bundle.
        var cut = 0
        while cut <= written.count {
            let dest = MemoryStore()
            let what = "after \(cut) of \(written.count) bytes"
            let source2 = ScriptedSource([Step(give: Array(written[..<cut]), fail: Lost())])
            assertLost(assertFails(try importBundle(dest, root, from: source2), "stream", what), what)
            try assertOnlyFrom(dest, source)
            cut += max(1, (written.count - cut) / 40)
        }
    }
}
