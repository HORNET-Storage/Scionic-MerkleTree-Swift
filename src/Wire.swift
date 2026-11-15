// What a receiver asks, and the frames that answer it.
//
// A receiver asks from the top down: for the record of a root, for a folder's
// entries, for a file's list, and for chunks. It asks for chunks by the file's
// hash and their numbers in it, or for one chunk by its hash.
//
// An answer is one frame, or for chunks one frame for each chunk. A frame never
// says which hash it belongs under: the receiver works the hash out from the
// frame's bytes, and holds it against a hash it already trusts.
//
// A request and a frame each start with one byte that says what they are.
// Numbers are big-endian.

/// The first byte of a frame, which says what the frame is.
public enum FrameTag {
    /// A tree's record. The frame is the record itself, whose first byte this is.
    public static let record: UInt8 = 0x20
    /// A file's whole list.
    public static let fileList: UInt8 = 0x21
    /// A folder's whole list.
    public static let folderList: UInt8 = 0x22
    /// A branch of a file's list, with the nodes that stand for the rest.
    public static let fileBranch: UInt8 = 0x23
    /// A branch of a folder's list, with the nodes that stand for the rest.
    public static let folderBranch: UInt8 = 0x24
    /// A chunk's bytes.
    public static let chunk: UInt8 = 0x25
    /// Which chunks of a file a peer holds.
    public static let have: UInt8 = 0x26
    /// The peer does not answer, and why.
    public static let refused: UInt8 = 0x27
}

private let askRecord: UInt8 = 0x30
private let askFolder: UInt8 = 0x31
private let askFolderBranch: UInt8 = 0x32
private let askFolderName: UInt8 = 0x33
private let askFile: UInt8 = 0x34
private let askFileBranch: UInt8 = 0x35
private let askFileBytes: UInt8 = 0x36
private let askChunks: UInt8 = 0x37
private let askChunk: UInt8 = 0x38
private let askHave: UInt8 = 0x39

extension Scionic {
    /// What starts a bundle: a tree written out as one stream of frames.
    public static let bundleMagic: [UInt8] = Array("SCIONIC".utf8) + [0x01]
    /// The most bytes a request may take. The longest one asks for a name in a
    /// folder: its first byte, the folder's hash, and the longest name with its
    /// length.
    public static let maxRequestBytes = 35 + maxNameBytes
}

/// The most bytes that are set aside for a frame before they have come. A
/// stream that claims a long frame and then sends nothing costs its reader no
/// more than this.
private let readStepBytes = 1 << 20

/// What a receiver asks a peer for.
public enum Request: Hashable, Sendable {
    /// The record of a root.
    case record(Root)
    /// All of a folder's entries.
    case folder(Hash)
    /// `count` of a folder's entries, from place `start`.
    case folderBranch(folder: Hash, start: UInt64, count: UInt32)
    /// What is under one name in a folder, or that the name is not there. The
    /// name is given as its UTF-8 bytes.
    case folderName(folder: Hash, name: [UInt8])
    /// All of a file's list.
    case file(Hash)
    /// `count` items of a file's list, from chunk number `start`.
    case fileBranch(file: Hash, start: UInt64, count: UInt32)
    /// The items of a file's list that hold `length` bytes from `offset`.
    case fileBytes(file: Hash, offset: UInt64, length: UInt64)
    /// `count` chunks of a file, from chunk number `start`.
    case chunks(file: Hash, start: UInt64, count: UInt32)
    /// One chunk, by its hash.
    case chunk(Hash)
    /// Which chunks of a file the peer holds.
    case have(Hash)

    /// What is under one name in a folder.
    public static func folderName(folder: Hash, name: String) -> Request {
        .folderName(folder: folder, name: Array(name.utf8))
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(49)
        func one(_ tag: UInt8, _ hash: Hash) {
            out.append(tag)
            out.append(hash)
        }
        func ranged(_ tag: UInt8, _ hash: Hash, _ start: UInt64, _ count: UInt32) {
            one(tag, hash)
            out.appendU64(start)
            out.appendU32(count)
        }
        switch self {
        case let .record(root):
            one(askRecord, root.hash)
        case let .folder(folder):
            one(askFolder, folder)
        case let .folderBranch(folder, start, count):
            ranged(askFolderBranch, folder, start, count)
        case let .folderName(folder, name):
            one(askFolderName, folder)
            out.appendU16(UInt16(truncatingIfNeeded: name.count))
            out.append(contentsOf: name)
        case let .file(file):
            one(askFile, file)
        case let .fileBranch(file, start, count):
            ranged(askFileBranch, file, start, count)
        case let .fileBytes(file, offset, length):
            one(askFileBytes, file)
            out.appendU64(offset)
            out.appendU64(length)
        case let .chunks(file, start, count):
            ranged(askChunks, file, start, count)
        case let .chunk(chunk):
            one(askChunk, chunk)
        case let .have(file):
            one(askHave, file)
        }
        return out
    }

    /// Reads a request. One that asks for nothing, or for a name that no folder
    /// can hold, is refused here.
    public init(decoding bytes: [UInt8]) throws {
        var reader = ByteReader(bytes, what: "a request")
        let tag = try reader.u8()
        let hash = try reader.hash()
        switch tag {
        case askRecord:
            self = .record(Root(hash: hash))
        case askFolder:
            self = .folder(hash)
        case askFile:
            self = .file(hash)
        case askChunk:
            self = .chunk(hash)
        case askHave:
            self = .have(hash)
        case askFolderBranch, askFileBranch, askChunks:
            let start = try reader.u64()
            let count = try reader.u32()
            guard count != 0, start < Scionic.maxListItems else {
                throw invalid("a request asks for nothing, or beyond any list")
            }
            switch tag {
            case askFolderBranch:
                self = .folderBranch(folder: hash, start: start, count: count)
            case askFileBranch:
                self = .fileBranch(file: hash, start: start, count: count)
            default:
                self = .chunks(file: hash, start: start, count: count)
            }
        case askFolderName:
            let length = Int(try reader.u16())
            let name = Array(try reader.take(length))
            guard utf8Text(name) != nil else {
                throw invalid("a name is not UTF-8")
            }
            try checkName(bytes: name)
            self = .folderName(folder: hash, name: name)
        case askFileBytes:
            let offset = try reader.u64()
            let length = try reader.u64()
            guard length != 0, !offset.addingReportingOverflow(length).overflow else {
                throw invalid("a request asks for no bytes, or beyond any file")
            }
            self = .fileBytes(file: hash, offset: offset, length: length)
        default:
            throw invalid("a request of an unknown kind")
        }
        try reader.finish()
    }
}

/// Why a peer does not answer.
public enum Refusal: UInt8, Hashable, Sendable {
    /// It does not hold what was asked for.
    case notHeld = 1
    /// What was asked for lies outside the list or the file.
    case outOfRange = 2
}

/// Which chunks of a file a peer holds: one bit a chunk, in the file's order. A
/// peer says this about itself, and nothing proves it.
public struct HaveMap: Hashable, Sendable {
    /// How many chunks the file has.
    public let count: UInt64
    private var bits: [UInt8]

    /// A map for a file of `count` chunks, with none held.
    public init(count: UInt64) throws {
        guard count <= Scionic.maxListItems else {
            throw invalid("a map for more chunks than a file can have")
        }
        self.count = count
        self.bits = [UInt8](repeating: 0, count: Int((count + 7) / 8))
    }

    /// Whether chunk `index` is held. A chunk beyond the count is not.
    public func get(_ index: UInt64) -> Bool {
        index < count && bits[Int(index / 8)] & (0x80 >> (index % 8)) != 0
    }

    /// Marks chunk `index` as held.
    public mutating func set(_ index: UInt64) throws {
        guard index < count else {
            throw invalid("a chunk beyond the end of the file")
        }
        bits[Int(index / 8)] |= 0x80 >> (index % 8)
    }

    /// How many chunks are held.
    public var held: UInt64 {
        bits.reduce(0) { $0 + UInt64($1.nonzeroBitCount) }
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + bits.count)
        out.appendU64(count)
        out.append(contentsOf: bits)
        return out
    }

    /// Reads a map. It has one bit for each chunk and no more, and the bits left
    /// over in its last byte are zero.
    public init(decoding bytes: [UInt8]) throws {
        var reader = ByteReader(bytes, what: "a map of held chunks")
        let count = try reader.u64()
        guard count <= Scionic.maxListItems, UInt64(reader.remaining) == (count + 7) / 8 else {
            throw invalid("a map of held chunks does not fit its count")
        }
        let bits = Array(try reader.take(reader.remaining))
        let spare = (8 - count % 8) % 8
        if let last = bits.last, last & UInt8((1 << spare) - 1) != 0 {
            throw invalid("a map of held chunks has bits past its count")
        }
        self.count = count
        self.bits = bits
    }
}

/// A frame, read.
public enum Frame: Hashable, Sendable {
    /// A record: the whole frame.
    case record(ArraySlice<UInt8>)
    /// A file's whole list.
    case fileList(ArraySlice<UInt8>)
    /// A folder's whole list.
    case folderList(ArraySlice<UInt8>)
    case fileBranch(FileBranch)
    case folderBranch(FolderBranch)
    /// A chunk's bytes.
    case chunk(ArraySlice<UInt8>)
    case have(HaveMap)
    case refused(Refusal)

    /// Reads a frame. This says what kind of frame it is and that it is well
    /// formed. It does not say that the frame is true: that is checked against
    /// a hash the receiver trusts.
    public init(decoding bytes: [UInt8]) throws {
        guard let tag = bytes.first else {
            throw invalid("a frame is empty")
        }
        let body = bytes[1...]
        switch tag {
        case FrameTag.record:
            self = .record(bytes[...])
        case FrameTag.fileList:
            self = .fileList(body)
        case FrameTag.folderList:
            self = .folderList(body)
        case FrameTag.fileBranch:
            self = .fileBranch(try FileBranch(decoding: Array(body)))
        case FrameTag.folderBranch:
            self = .folderBranch(try FolderBranch(decoding: Array(body)))
        case FrameTag.chunk:
            guard !body.isEmpty, body.count <= Scionic.maxChunkBytes else {
                throw invalid("a chunk does not hold 1 byte to 8 MiB")
            }
            self = .chunk(body)
        case FrameTag.have:
            self = .have(try HaveMap(decoding: Array(body)))
        case FrameTag.refused:
            guard body.count == 1, let why = Refusal(rawValue: body[body.startIndex]) else {
                throw invalid("a refusal of an unknown kind")
            }
            self = .refused(why)
        default:
            throw invalid("a frame of an unknown kind")
        }
    }
}

private func framed<Body: Collection>(_ tag: UInt8, _ body: Body) -> [UInt8] where Body.Element == UInt8 {
    var frame: [UInt8] = []
    frame.reserveCapacity(1 + body.count)
    frame.append(tag)
    frame.append(contentsOf: body)
    return frame
}

/// The frame for a file's whole list.
public func fileListFrame(_ list: [UInt8]) -> [UInt8] {
    framed(FrameTag.fileList, list)
}

/// The frame for a folder's whole list.
public func folderListFrame(_ list: [UInt8]) -> [UInt8] {
    framed(FrameTag.folderList, list)
}

public func fileBranchFrame(_ branch: FileBranch) -> [UInt8] {
    framed(FrameTag.fileBranch, branch.encode())
}

public func folderBranchFrame(_ branch: FolderBranch) -> [UInt8] {
    framed(FrameTag.folderBranch, branch.encode())
}

/// The frame for a chunk's bytes.
public func chunkFrame<Bytes: Collection>(_ chunk: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
    framed(FrameTag.chunk, chunk)
}

public func haveFrame(_ map: HaveMap) -> [UInt8] {
    framed(FrameTag.have, map.encode())
}

public func refusedFrame(_ why: Refusal) -> [UInt8] {
    [FrameTag.refused, why.rawValue]
}

// MARK: - Streams

/// Where bytes are read from: a file, a connection, a bundle.
public protocol ByteSource: AnyObject {
    /// Reads at most `buffer.count` bytes into `buffer`, and says how many. It
    /// gives zero only when there is nothing more to read, and an error when
    /// reading failed.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

/// Where bytes are written to.
public protocol ByteSink: AnyObject {
    /// Writes all of `bytes`, or throws.
    func write(_ bytes: UnsafeRawBufferPointer) throws

    /// Sends on what the sink has kept back, if it keeps anything back. It is
    /// called once a request or an answer is written whole. A sink that keeps
    /// nothing back need not have it.
    func flush() throws
}

extension ByteSink {
    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }

    public func flush() throws {}
}

/// Sends on what `sink` has kept back.
func flush(_ sink: any ByteSink, _ operation: String) throws {
    do {
        try sink.flush()
    } catch {
        throw streamFailure(error, operation)
    }
}

/// Reads from `source` until `buffer` is full. A source that ends first, or that
/// says it gave more than it was asked for, is an error.
func readExactly(_ source: any ByteSource, _ buffer: UnsafeMutableRawBufferPointer, endsEarly: ScionicError) throws {
    var filled = 0
    while filled < buffer.count {
        let count = try readSome(source, UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]))
        if count == 0 {
            throw endsEarly
        }
        filled += count
    }
}

/// One read from `source`, held to what a read may give.
func readSome(_ source: any ByteSource, _ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    let count = try source.read(into: buffer)
    guard count >= 0, count <= buffer.count else {
        throw ScionicError.invariant("a reader gave more bytes than it was asked for")
    }
    return count
}

/// Writes one frame to a stream: its length as four bytes, then the frame.
public func writeFrame(_ sink: any ByteSink, _ frame: [UInt8]) throws {
    guard frame.count <= Int(UInt32.max) else {
        throw ScionicError.limitExceeded(what: "a frame", limit: UInt64(UInt32.max), requested: UInt64(frame.count))
    }
    var header: [UInt8] = []
    header.appendU32(UInt32(frame.count))
    do {
        try sink.write(header)
        try sink.write(frame)
    } catch {
        throw streamFailure(error, "write a frame")
    }
}

/// Writes the frame that `tag` and `body` make, without making it: the body of
/// a chunk's frame is megabytes long, and is written from where it is.
func writeFrame(_ sink: any ByteSink, tag: UInt8, body: [UInt8]) throws {
    try body.withUnsafeBytes { try writeFrame(sink, tag: tag, body: $0) }
}

/// Writes the frame that `tag` and `body` make, without making it.
func writeFrame(_ sink: any ByteSink, tag: UInt8, body: UnsafeRawBufferPointer) throws {
    guard body.count < Int(UInt32.max) else {
        throw ScionicError.limitExceeded(what: "a frame", limit: UInt64(UInt32.max), requested: UInt64(body.count) + 1)
    }
    var header: [UInt8] = []
    header.appendU32(UInt32(body.count + 1))
    header.append(tag)
    do {
        try sink.write(header)
        try sink.write(body)
    } catch {
        throw streamFailure(error, "write a frame")
    }
}

/// What comes next on a stream of frames.
enum Next {
    /// A frame, which is in the buffer that was given to read it into.
    case frame
    /// A length of zero. Where answers are sent, it ends one answer.
    case end
    /// The stream has ended, between two frames.
    case closed
}

/// Writes a length of zero to a stream: the end of an answer.
func writeEnd(_ sink: any ByteSink) throws {
    do {
        try sink.write([0, 0, 0, 0])
    } catch {
        throw streamFailure(error, "write a frame")
    }
}

/// Reads what comes next on a stream, a frame into `frame`, which is emptied
/// first. One buffer serves frame after frame, so that memory is not taken
/// afresh for each: memory that is used again costs much less than fresh
/// memory, which a system has to find and clear first.
///
/// A frame longer than `limit` is refused before any of it is read, and a
/// stream that ends inside a frame is an error. A frame's bytes are set aside
/// as they come, a megabyte at a time, so that what a peer only says it will
/// send costs nothing until it is sent.
func readNext(_ source: any ByteSource, limit: Int, into frame: inout [UInt8]) throws -> Next {
    do {
        return try readNextFrom(source, limit: limit, into: &frame)
    } catch {
        throw streamFailure(error, "read a frame")
    }
}

private func readNextFrom(_ source: any ByteSource, limit: Int, into frame: inout [UInt8]) throws -> Next {
    let cutShort = invalid("a stream ends inside a frame")
    var header: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    let ended = try withUnsafeMutableBytes(of: &header) { header -> Bool in
        let first = try readSome(source, header)
        if first == 0 {
            return true
        }
        try readExactly(source, UnsafeMutableRawBufferPointer(rebasing: header[first...]), endsEarly: cutShort)
        return false
    }
    if ended {
        return .closed
    }
    let length = Int(UInt32(header.0) << 24 | UInt32(header.1) << 16 | UInt32(header.2) << 8 | UInt32(header.3))
    if length == 0 {
        return .end
    }
    guard length <= limit else {
        throw ScionicError.limitExceeded(what: "a frame", limit: UInt64(limit), requested: UInt64(length))
    }
    frame.removeAll(keepingCapacity: true)
    while frame.count < length {
        let held = frame.count
        let more = min(length - held, readStepBytes)
        frame.append(contentsOf: repeatElement(0, count: more))
        try frame.withUnsafeMutableBytes { raw in
            try readExactly(source, UnsafeMutableRawBufferPointer(rebasing: raw[held...]), endsEarly: cutShort)
        }
    }
    return .frame
}

/// Reads one frame from a stream, or nil when the stream has ended. A frame
/// longer than `limit` is refused before any of it is read, and a stream that
/// ends inside a frame is an error.
public func readFrame(_ source: any ByteSource, limit: Int) throws -> [UInt8]? {
    var frame: [UInt8] = []
    switch try readNext(source, limit: limit, into: &frame) {
    case .frame:
        return frame
    case .end:
        throw invalid("a frame is empty")
    case .closed:
        return nil
    }
}
