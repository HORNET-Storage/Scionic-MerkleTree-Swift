import XCTest
@testable import ScionicMerkleTree

private func everyRequest() -> [Request] {
    let hash = Hash.of(bytes("x"))
    return [
        .record(Root(hash: hash)),
        .folder(hash),
        .folderBranch(folder: hash, start: 3, count: 9),
        .folderName(folder: hash, name: "model.safetensors"),
        .file(hash),
        .fileBranch(file: hash, start: 100, count: 100),
        .fileBytes(file: hash, offset: 500 << 30, length: 1 << 30),
        .chunks(file: hash, start: 100, count: 101),
        .chunk(hash),
        .have(hash),
    ]
}

final class WireTests: XCTestCase {
    func testEveryRequestReadsBackAndIsReadInOneWayOnly() throws {
        for request in everyRequest() {
            let encoded = request.encode()
            XCTAssertEqual(try Request(decoding: encoded), request)
            for cut in 0..<encoded.count {
                XCTAssertThrowsError(try Request(decoding: Array(encoded[..<cut])), "\(request) cut at \(cut)")
            }
            XCTAssertThrowsError(try Request(decoding: encoded + [0]))
        }
        var tags: [UInt8] = []
        for request in everyRequest() where tags.last != request.encode()[0] {
            tags.append(request.encode()[0])
        }
        XCTAssertEqual(tags, Array(0x30...0x39))
        // "Chunks 100 to 200 of this file" is 45 bytes, whatever the file.
        XCTAssertEqual(everyRequest()[7].encode().count, 45)
    }

    func testARequestForNothingOrForANameNoFolderHoldsIsRefused() throws {
        let hash = Hash.of(bytes("x"))
        func ranged(_ tag: UInt8, _ start: UInt64, _ count: UInt32) throws -> Request {
            try Request(decoding: [tag] + hash.bytes + u64be(start) + u32be(count))
        }
        for tag: UInt8 in [0x32, 0x35, 0x37] {
            XCTAssertNoThrow(try ranged(tag, 0, 1))
            XCTAssertThrowsError(try ranged(tag, 0, 0))
            XCTAssertThrowsError(try ranged(tag, Scionic.maxListItems, 1))
        }
        func named(_ name: [UInt8]) throws -> Request {
            try Request(decoding: [0x33] + hash.bytes + u16be(UInt16(name.count)) + name)
        }
        XCTAssertNoThrow(try named(bytes("a")))
        for name: [UInt8] in [[], bytes("."), bytes(".."), bytes("a/b"), bytes("a") + [0], [0xFF]] {
            XCTAssertThrowsError(try named(name), "\(name)")
        }
        func stretch(_ offset: UInt64, _ length: UInt64) throws -> Request {
            try Request(decoding: [0x36] + hash.bytes + u64be(offset) + u64be(length))
        }
        XCTAssertNoThrow(try stretch(0, 1))
        XCTAssertThrowsError(try stretch(0, 0))
        XCTAssertThrowsError(try stretch(UInt64.max, 1))
        XCTAssertThrowsError(try Request(decoding: [0x3A] + hash.bytes))
    }

    func testAMapOfHeldChunksHasOneBitAChunk() throws {
        var map = try HaveMap(count: 11)
        XCTAssertEqual(map.encode().count, 8 + 2)
        for index: UInt64 in [0, 3, 10] {
            try map.set(index)
        }
        XCTAssertThrowsError(try map.set(11))
        XCTAssertEqual(map.held, 3)
        XCTAssertEqual((0..<16).filter { map.get($0) }, [0, 3, 10])
        let encoded = map.encode()
        XCTAssertEqual(Array(encoded[8...]), [0b1001_0000, 0b0010_0000])
        XCTAssertEqual(try HaveMap(decoding: encoded), map)

        // A bit past the count, a byte too many and a byte too few.
        var past = encoded
        past[9] |= 0b0001_0000
        XCTAssertThrowsError(try HaveMap(decoding: past))
        XCTAssertThrowsError(try HaveMap(decoding: encoded + [0]))
        XCTAssertThrowsError(try HaveMap(decoding: Array(encoded[..<9])))
        // A terabyte file's map is about 60 KB.
        XCTAssertEqual(try HaveMap(count: 500_000).encode().count, 8 + 62_500)
        XCTAssertEqual(try HaveMap(decoding: HaveMap(count: 0).encode()).count, 0)
        XCTAssertEqual(try HaveMap(decoding: HaveMap(count: 8).encode()).count, 8)
    }

    func testFramesAreToldApartByTheirFirstByte() throws {
        XCTAssertEqual(try Frame(decoding: chunkFrame(bytes("abc"))), .chunk(bytes("abc")[...]))
        let list = [UInt8](repeating: 7, count: 36)
        XCTAssertEqual(try Frame(decoding: fileListFrame(list)), .fileList(list[...]))
        XCTAssertEqual(try Frame(decoding: folderListFrame([])), .folderList([][...]))
        XCTAssertEqual(try Frame(decoding: refusedFrame(.notHeld)), .refused(.notHeld))
        XCTAssertEqual(try Frame(decoding: refusedFrame(.outOfRange)), .refused(.outOfRange))
        let map = try HaveMap(count: 3)
        XCTAssertEqual(try Frame(decoding: haveFrame(map)), .have(map))
        XCTAssertEqual(try Frame(decoding: [0x20, 1]), .record([0x20, 1][...]))
        let bad: [[UInt8]] = [[], [0x25], [0x27], [0x27, 0], [0x27, 3], [0x27, 1, 1], [0x28], [0x1F]]
        for frame in bad {
            XCTAssertThrowsError(try Frame(decoding: frame), "\(frame)")
        }
        XCTAssertThrowsError(try Frame(decoding: chunkFrame([UInt8](repeating: 0, count: Scionic.maxChunkBytes + 1))))
        XCTAssertNoThrow(try Frame(decoding: chunkFrame([UInt8](repeating: 0, count: Scionic.maxChunkBytes))))
    }

    func testFramesGoThroughAStreamWholeOrNotAtAll() throws {
        let stream = BytesSink()
        try writeFrame(stream, bytes("one"))
        try writeFrame(stream, bytes("three"))
        let input = BytesSource(stream.bytes)
        XCTAssertEqual(try readFrame(input, limit: 16), bytes("one"))
        XCTAssertEqual(try readFrame(input, limit: 16), bytes("three"))
        XCTAssertNil(try readFrame(input, limit: 16))

        // A frame over the limit is refused before it is read.
        XCTAssertThrowsError(try readFrame(BytesSource(stream.bytes), limit: 2)) { error in
            guard case ScionicError.limitExceeded = error else {
                return XCTFail("\(error)")
            }
        }
        // A stream that ends inside a length or inside a frame.
        for cut in [1, 3, 5, 6] {
            XCTAssertThrowsError(try readFrame(BytesSource(Array(stream.bytes[..<cut])), limit: 16), "cut at \(cut)")
        }
        XCTAssertThrowsError(try readFrame(BytesSource([0, 0, 0, 0]), limit: 16))
    }
}
