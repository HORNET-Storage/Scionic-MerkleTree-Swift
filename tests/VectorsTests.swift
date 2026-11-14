// The shared vectors: what the Rust, Go and Swift libraries are held to, byte
// for byte.
//
// spec/vectors/manifest.json is made by the Rust library, whose tests fail when
// the file and that library disagree. Here the Swift library builds the same
// trees from the same descriptions, and has to arrive at the same bytes: every
// root, record, list, chunk, branch, answer and exchange. And it has to refuse
// every input that the manifest says must be refused.
//
// spec/fastcdc-vectors/manifest.json says, for inputs of several kinds, where
// each chunk ends and what each chunk hashes to. Two builders give the same file
// the same hash only when both cut at the same bytes, so one wrong gear entry,
// mask or off-by-one would make trees that look valid and never share a chunk
// with anyone. These vectors are where that shows.

import Foundation
import XCTest
@testable import ScionicMerkleTree

private let vectorsManifestSHA256 = "b10f53a722468ee53c69952f2b9ba1421a02608528be6ae4df753a35d0a5cba8"
private let fastcdcManifestSHA256 = "7624a7eb87315adc6920aac0cec2155ed7e28b3271396c6ad242312ee6b1abc5"

struct VectorsManifest: Decodable {
    let format: String
    let bytes: String
    let trees: [VectorTree]
    let branches: [VectorBranch]
    let names: [VectorName]
    let answers: [VectorAnswer]
    let connection: VectorConnection
    let refused: [VectorRefused]
}

/// A file as its parts, or a folder as its entries. One of `file` and `folder`
/// is there: an empty file has no parts, and an empty folder has no entries.
struct VectorNode: Decodable {
    let name: String?
    let extra: [String: String]?
    let file: [VectorPart]?
    let folder: [VectorNode]?
}

struct VectorPart: Decodable {
    let seed: String
    let length: Int
}

struct VectorTree: Decodable {
    let name: String
    let chunking: String
    let extra: [String: String]
    let top: VectorNode
    let root: String
    let rootHash: String
    let record: String
    let size: UInt64
    let chunks: UInt64
    let chunkBytes: UInt64
    let listBytes: UInt64
    let lists: [VectorList]
    let chunkList: [VectorChunk]
    let bundleLength: Int
    let bundleSha256: String
}

struct VectorList: Decodable, Equatable {
    let kind: String
    let hash: String
    let size: UInt64
    let bytes: String
}

struct VectorChunk: Decodable, Equatable {
    let hash: String
    let length: UInt64
}

struct VectorTarget: Decodable {
    let kind: String
    let hash: String
    let size: UInt64
}

struct VectorBranch: Decodable {
    let tree: String
    let path: String
    let of: VectorTarget
    let start: UInt64
    let end: UInt64
    let startsAtByte: UInt64?
    let frame: String
}

struct VectorName: Decodable {
    let tree: String
    let path: String
    let of: VectorTarget
    let name: String
    let found: Bool
    let frame: String
}

struct VectorAnswer: Decodable {
    let tree: String
    let what: String
    let request: String
    let frames: [String]
}

struct VectorConnection: Decodable {
    let tree: String
    let sent: String
    let received: String
}

struct VectorRefused: Decodable {
    let kind: String
    let what: String
    let bytes: String?
    let chunking: String?
    let against: VectorTarget?
    let name: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case kind = "as"
        case what, bytes, chunking, against, name, text
    }
}

private let targetShape = Shape.object(["kind": .value, "hash": .value, "size": .value])

private let vectorShapes: [String: Shape] = [
    "node": .object(
        [
            "name": .value,
            "extra": .map(.value),
            "file": .array(.object(["seed": .value, "length": .value])),
            "folder": .array(.named("node")),
        ],
        optional: ["name", "extra", "file", "folder"]
    ),
]

private let vectorsShape = Shape.object([
    "format": .value,
    "bytes": .value,
    "trees": .array(.object([
        "name": .value,
        "chunking": .value,
        "extra": .map(.value),
        "top": .named("node"),
        "root": .value,
        "root_hash": .value,
        "record": .value,
        "size": .value,
        "chunks": .value,
        "chunk_bytes": .value,
        "list_bytes": .value,
        "lists": .array(.object(["kind": .value, "hash": .value, "size": .value, "bytes": .value])),
        "chunk_list": .array(.object(["hash": .value, "length": .value])),
        "bundle_length": .value,
        "bundle_sha256": .value,
    ])),
    "branches": .array(.object(
        [
            "tree": .value, "path": .value, "of": targetShape, "start": .value, "end": .value,
            "starts_at_byte": .value, "frame": .value,
        ],
        optional: ["starts_at_byte"]
    )),
    "names": .array(.object([
        "tree": .value, "path": .value, "of": targetShape, "name": .value, "found": .value, "frame": .value,
    ])),
    "answers": .array(.object(["tree": .value, "what": .value, "request": .value, "frames": .array(.value)])),
    "connection": .object(["tree": .value, "sent": .value, "received": .value]),
    "refused": .array(.object(
        [
            "as": .value, "what": .value, "bytes": .value, "chunking": .value, "against": targetShape,
            "name": .value, "text": .value,
        ],
        optional: ["bytes", "chunking", "against", "name", "text"]
    )),
])

func readVectors() throws -> VectorsManifest {
    let manifest = try readManifest(
        VectorsManifest.self,
        "vectors/manifest.json",
        sha256: vectorsManifestSHA256,
        shape: vectorsShape,
        names: vectorShapes
    )
    guard manifest.format == "scionic-vectors-1" else {
        throw TestFailure("the manifest is of the format \(manifest.format)")
    }
    return manifest
}

func targetOf(_ described: VectorTarget) throws -> Target {
    let kind: Kind
    switch described.kind {
    case "file":
        kind = .file
    case "folder":
        kind = .folder
    default:
        throw TestFailure("the manifest names a \(described.kind)")
    }
    return Target(kind: kind, hash: try Hash(hex: described.hash), size: described.size)
}

func extraOf(_ values: [String: String]?) throws -> ExtraData {
    var extra = ExtraData()
    for (name, value) in values ?? [:] {
        try extra.insert(name, text: value)
    }
    return extra
}

/// The bytes of a file that a vector describes as its parts.
func contentOf(_ node: VectorNode) -> [UInt8] {
    (node.file ?? []).flatMap { corpusBytes($0.seed, $0.length) }
}

/// Builds what a vector's description says: a file as parts made from seeds, or
/// a folder of named files and folders. With `fromStream`, a file's bytes are
/// given as a stream, in reads of awkward lengths, and not as bytes that lie in
/// memory.
func buildNode(_ builder: Builder, _ node: VectorNode, fromStream: Bool) throws -> Target {
    if (node.file == nil) == (node.folder == nil) {
        throw TestFailure("\(node.name ?? "the top") is described as neither a file nor a folder, or as both")
    }
    if node.file != nil {
        let content = contentOf(node)
        return fromStream ? try builder.file(from: BytesSource(content, awkward: true)) : try builder.file(bytes: content)
    }
    var entries: [Entry] = []
    for child in node.folder ?? [] {
        guard let name = child.name else {
            throw TestFailure("an entry has no name")
        }
        entries.append(try Entry(name: name, target: buildNode(builder, child, fromStream: fromStream), extra: extraOf(child.extra)))
    }
    // The entries are given in the wrong order on purpose: a builder puts them
    // in the order of their names.
    return try builder.folder(entries.reversed())
}

/// A tree of the manifest, built here.
struct BuiltVector {
    let store: MemoryStore
    let root: Root

    /// The file or folder at a path of the tree. The empty path is the top.
    func at(_ path: String) throws -> Target {
        if path.isEmpty {
            return try recordOf(store, root).top
        }
        guard let entry = try lookup(store, root, path: path) else {
            throw TestFailure("\(path) is not in the tree")
        }
        return entry.target
    }
}

func buildVector(_ described: VectorTree, fromStream: Bool = false) throws -> BuiltVector {
    let store = MemoryStore()
    let builder = Builder(store: store, chunking: try Chunking(tag: Array(described.chunking.utf8)))
    let root = try builder.finish(top: buildNode(builder, described.top, fromStream: fromStream), extra: extraOf(described.extra))
    return BuiltVector(store: store, root: root)
}

/// The tree of the manifest that the branches, the names and the answers are
/// taken from.
func sampleOf(_ manifest: VectorsManifest, _ name: String) throws -> BuiltVector {
    guard let described = manifest.trees.first(where: { $0.name == name }) else {
        throw TestFailure("the manifest has no tree named \(name)")
    }
    return try buildVector(described)
}

/// The frames of a stream, as they follow one another: each its length in four
/// bytes, then its bytes.
func framesOf(_ stream: ArraySlice<UInt8>) throws -> [[UInt8]] {
    var frames: [[UInt8]] = []
    var at = stream.startIndex
    while at < stream.endIndex {
        guard stream.endIndex - at >= 4 else {
            throw TestFailure("a stream ends inside a length")
        }
        let length = stream[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard stream.endIndex - at - 4 >= length else {
            throw TestFailure("a stream ends inside a frame")
        }
        frames.append(Array(stream[(at + 4)..<(at + 4 + length)]))
        at += 4 + length
    }
    return frames
}

struct FastCDCManifest: Decodable {
    let spec: String
    let cases: [FastCDCCase]
}

struct FastCDCCase: Decodable {
    let name: String
    let kind: String
    let seed: String?
    let length: Int
    let boundaries: [Int]
    let chunkSha256: [String]
    let fileHash: String
    let base: String?
    let op: String?
    let offset: Int?
    let editLength: Int?
    let payloadSeed: String?
    let reused: [Bool]?
}

private let fastcdcShape = Shape.object([
    "spec": .value,
    "cases": .array(.object(
        [
            "name": .value, "kind": .value, "seed": .value, "length": .value, "boundaries": .array(.value),
            "chunk_sha256": .array(.value), "file_hash": .value, "base": .value, "op": .value, "offset": .value,
            "edit_length": .value, "payload_seed": .value, "reused": .array(.value),
        ],
        optional: ["seed", "base", "op", "offset", "edit_length", "payload_seed", "reused"]
    )),
])

private func readFastCDCVectors() throws -> FastCDCManifest {
    let manifest = try readManifest(
        FastCDCManifest.self,
        "fastcdc-vectors/manifest.json",
        sha256: fastcdcManifestSHA256,
        shape: fastcdcShape
    )
    guard manifest.spec == "fastcdc-v1", manifest.cases.count >= 11 else {
        throw TestFailure("the manifest is of another kind, or lists too few cases")
    }
    return manifest
}

/// The input of a case, made from what the manifest says about it.
private func inputOf(_ chunkCase: FastCDCCase, _ cases: [FastCDCCase]) throws -> [UInt8] {
    switch chunkCase.kind {
    case "corpus":
        guard let seed = chunkCase.seed else {
            throw TestFailure("\(chunkCase.name) has no seed")
        }
        return corpusBytes(seed, chunkCase.length)
    case "zeros":
        return [UInt8](repeating: 0, count: chunkCase.length)
    case "edit":
        guard let baseName = chunkCase.base, let base = cases.first(where: { $0.name == baseName }) else {
            throw TestFailure("\(chunkCase.name) edits a case the manifest does not have")
        }
        let input = try inputOf(base, cases)
        let offset = chunkCase.offset ?? 0
        let editLength = chunkCase.editLength ?? 0
        switch chunkCase.op {
        case "insert":
            return Array(input[..<offset]) + corpusBytes(chunkCase.payloadSeed ?? "", editLength) + Array(input[offset...])
        case "delete":
            return Array(input[..<offset]) + Array(input[(offset + editLength)...])
        default:
            throw TestFailure("\(chunkCase.name) has the unknown op \(chunkCase.op ?? "none")")
        }
    default:
        throw TestFailure("\(chunkCase.name) has the unknown kind \(chunkCase.kind)")
    }
}

final class VectorsTests: XCTestCase {
    func testEveryTreeOfTheSharedVectorsIsBuiltByteForByte() throws {
        let manifest = try readVectors()
        XCTAssertGreaterThanOrEqual(manifest.trees.count, 7, "the manifest lists too few trees")
        for described in manifest.trees {
            let built = try buildVector(described)
            let name = described.name
            XCTAssertEqual(built.root.text, described.root, name)
            XCTAssertEqual(built.root.hash.hex, described.rootHash, name)
            XCTAssertEqual(try Root(text: described.root), built.root, name)
            let record = try recordOf(built.store, built.root)
            XCTAssertEqual(hexText(record.encode()), described.record, name)
            XCTAssertEqual(record.top.size, described.size, name)
            XCTAssertEqual(record.totals.chunks, described.chunks, name)
            XCTAssertEqual(record.totals.chunkBytes, described.chunkBytes, name)
            XCTAssertEqual(record.totals.listBytes, described.listBytes, name)
            XCTAssertEqual(record.chunking.tag, described.chunking, name)

            // The tree as one stream gives every list and chunk once, parents
            // first.
            let bundle = BytesSink()
            try exportBundle(built.store, built.root, to: bundle)
            XCTAssertEqual(bundle.bytes.count, described.bundleLength, name)
            XCTAssertEqual(Hash.of(bundle.bytes).hex, described.bundleSha256, name)
            XCTAssertEqual(Array(bundle.bytes.prefix(8)), Scionic.bundleMagic, name)
            var lists: [VectorList] = []
            var chunks: [VectorChunk] = []
            for frame in try framesOf(bundle.bytes[Scionic.bundleMagic.count...]) {
                let body = Array(frame[1...])
                switch frame[0] {
                case FrameTag.fileList:
                    let list = try FileList(decoding: body)
                    lists.append(VectorList(kind: "file", hash: list.hash.hex, size: list.size, bytes: hexText(body)))
                case FrameTag.folderList:
                    let list = try FolderList(decoding: body)
                    lists.append(VectorList(kind: "folder", hash: list.hash.hex, size: list.size, bytes: hexText(body)))
                case FrameTag.chunk:
                    chunks.append(VectorChunk(hash: Hash.of(body).hex, length: UInt64(body.count)))
                default:
                    break
                }
            }
            XCTAssertEqual(lists, described.lists, "\(name): the lists are not the manifest's")
            XCTAssertEqual(chunks, described.chunkList, "\(name): the chunks are not the manifest's")

            // What is built passes the checks of a tree that is taken in.
            _ = try verify(built.store, built.root, options: VerifyOptions(rechunk: true))
            // A file's bytes that come as a stream give the same tree.
            let streamed = try buildVector(described, fromStream: true)
            XCTAssertEqual(streamed.root, built.root, "\(name): built from streams, the tree is another one")
            XCTAssertTrue(try sameStores(streamed.store, built.store), name)
            // The bundle is taken in, and so is the tree from a holder of it.
            let imported = MemoryStore()
            try importBundle(imported, built.root, from: BytesSource(bundle.bytes, awkward: true))
            let fetched = MemoryStore()
            try fetch(fetched, built.root, from: Responder(built.store))
            XCTAssertTrue(try sameStores(imported, built.store), "\(name): the imported tree is not the built one")
            XCTAssertTrue(try sameStores(fetched, built.store), "\(name): the fetched tree is not the built one")
            // Every file reads back as the bytes it was built from.
            try checkReadsBack(described.top, record.top, fetched, name)
        }
    }

    private func checkReadsBack(_ node: VectorNode, _ target: Target, _ store: MemoryStore, _ tree: String) throws {
        let name = node.name ?? "the top"
        if node.file != nil {
            XCTAssertEqual(try readFile(store, target), contentOf(node), "\(tree): \(name) does not read back")
            return
        }
        let list = try folderOf(store, target)
        let children = node.folder ?? []
        XCTAssertEqual(list.count, UInt64(children.count), "\(tree): \(name) holds other entries")
        for child in children {
            guard let entry = list.get(child.name ?? "") else {
                XCTFail("\(tree): \(child.name ?? "") is not in its folder")
                continue
            }
            XCTAssertEqual(entry.extra, try extraOf(child.extra), "\(tree): \(child.name ?? "") has other extra data")
            try checkReadsBack(child, entry.target, store, tree)
        }
    }

    func testEveryBranchOfTheSharedVectorsIsShownAndCheckedByteForByte() throws {
        let manifest = try readVectors()
        XCTAssertGreaterThanOrEqual(manifest.branches.count, 9, "the manifest lists too few branches")
        for shown in manifest.branches {
            let sample = try sampleOf(manifest, shown.tree)
            let of = try targetOf(shown.of)
            XCTAssertEqual(try sample.at(shown.path), of, "\(shown.path) is not what the manifest says is there")
            let given = try Frame(decoding: hexBytes(shown.frame))
            let label = "\(shown.path) \(shown.start) to \(shown.end)"
            if of.kind == .file {
                let branch = try fileOf(sample.store, of).open(start: shown.start, end: shown.end)
                XCTAssertEqual(hexText(fileBranchFrame(branch)), shown.frame, label)
                guard case let .fileBranch(given) = given, let startsAt = shown.startsAtByte else {
                    XCTFail("\(label): the manifest's frame is no branch of a file's list")
                    continue
                }
                XCTAssertEqual(try given.check(file: of, chunking: nil), startsAt, label)
                XCTAssertEqual(try given.check(file: of, chunking: smallChunks()), startsAt, label)
                XCTAssertEqual(given.start, shown.start, label)
                XCTAssertEqual(UInt64(given.items.count), shown.end - shown.start, label)
                continue
            }
            let list = try folderOf(sample.store, of)
            let branch = try list.open(start: shown.start, end: shown.end)
            XCTAssertEqual(hexText(folderBranchFrame(branch)), shown.frame, label)
            guard case let .folderBranch(given) = given else {
                XCTFail("\(label): the manifest's frame is no branch of a folder's list")
                continue
            }
            try given.check(folder: of)
            XCTAssertEqual(given.entries, Array(list.entries[Int(shown.start)..<Int(shown.end)]), label)
        }
    }

    func testEveryNameOfTheSharedVectorsIsAnsweredByteForByte() throws {
        let manifest = try readVectors()
        XCTAssertGreaterThanOrEqual(manifest.names.count, 8, "the manifest lists too few names")
        var found = 0
        var absent = 0
        for asked in manifest.names {
            let sample = try sampleOf(manifest, asked.tree)
            let of = try targetOf(asked.of)
            XCTAssertEqual(try sample.at(asked.path), of, "\(asked.path) is not what the manifest says is there")
            let list = try folderOf(sample.store, of)
            let label = "\(asked.name) in \(asked.path)"
            XCTAssertEqual(hexText(folderBranchFrame(try list.openName(asked.name))), asked.frame, label)
            guard case let .folderBranch(given) = try Frame(decoding: hexBytes(asked.frame)) else {
                XCTFail("\(label): the frame is no branch of a folder's list")
                continue
            }
            let entry = try given.check(folder: of, name: asked.name)
            XCTAssertEqual(entry != nil, asked.found, label)
            XCTAssertEqual(entry, list.get(asked.name), "\(label): the answer is not what the folder holds")
            if entry != nil {
                found += 1
            } else {
                absent += 1
            }
        }
        XCTAssertTrue(found > 0 && absent > 0, "the manifest has no name that is there, or none that is not")
    }

    func testEveryRequestOfTheSharedVectorsIsAnsweredByteForByte() throws {
        let manifest = try readVectors()
        XCTAssertGreaterThanOrEqual(manifest.answers.count, 12, "the manifest lists too few answers")
        var kinds = Set<UInt8>()
        for asked in manifest.answers {
            let sample = try sampleOf(manifest, asked.tree)
            let request = try hexBytes(asked.request)
            XCTAssertEqual(try Request(decoding: request).encode(), request, "\(asked.what): the request does not read back")
            kinds.insert(request[0])
            var frames: [String] = []
            try Responder(sample.store).answer(request) { frames.append(hexText($0)) }
            XCTAssertEqual(frames, asked.frames, asked.what)
            for frame in asked.frames {
                _ = try Frame(decoding: hexBytes(frame))
            }
        }
        XCTAssertEqual(kinds.count, 10, "the manifest asks \(kinds.count) kinds of request, and there are 10")
    }

    func testTheExchangeOfTheSharedVectorsIsTheSameOnAConnection() throws {
        let manifest = try readVectors()
        let sample = try sampleOf(manifest, manifest.connection.tree)
        let sent = try hexBytes(manifest.connection.sent)
        let want = try hexBytes(manifest.connection.received)
        // What a holder of the tree sends back is the manifest's bytes, whether
        // its writer keeps bytes back or not.
        let received = BytesSink()
        try serve(sample.store, from: BytesSource(sent), to: received)
        XCTAssertEqual(received.bytes, want, "the holder sent back other bytes")
        let buffered = BytesSink(keepsBack: true)
        try serve(sample.store, from: BytesSource(sent, awkward: true), to: buffered)
        XCTAssertEqual(buffered.bytes, want, "through a writer that keeps bytes back, the holder sent back other bytes")

        // And an asker on a connection sends the manifest's bytes, and is given
        // the frames that the manifest lists for those requests.
        var requests: [Asked] = []
        var expected: [[String]] = []
        for request in try framesOf(sent[...]) {
            requests.append(Asked(request: request, limit: 1 << 20))
            let listed = manifest.answers.filter { $0.request == hexText(request) }
            XCTAssertFalse(listed.isEmpty, "the connection sends a request that the answers do not list")
            expected.append(listed.first?.frames ?? [])
        }
        XCTAssertEqual(requests.count, 3, "the connection sends \(requests.count) requests")
        // The connection holds on the way to the holder what an asker may send
        // ahead, and on the way back one byte.
        var got = [[String]](repeating: [], count: requests.count)
        let (asked, wrote, served) = connected(sample.store, toServer: Scionic.requestsAheadBytes, toClient: 1) { peer in
            try peer.askAll(requests) { place, frame in
                got[place].append(hexText(frame))
            }
        }
        XCTAssertNoThrow(try asked.get())
        XCTAssertNil(served)
        XCTAssertEqual(wrote.all, sent, "the asker sent other bytes")
        XCTAssertEqual(got, expected)
    }

    func testEverythingTheSharedVectorsSayMustBeRefusedIsRefused() throws {
        let manifest = try readVectors()
        XCTAssertGreaterThanOrEqual(manifest.refused.count, 76, "the manifest lists too few inputs that must be refused")
        var kinds: [String: Int] = [:]
        for forged in manifest.refused {
            kinds[forged.kind, default: 0] += 1
            let label = "\(forged.kind): \(forged.what)"
            let content = try hexBytes(forged.bytes ?? "")
            // What the forgery is held against is read first, so that only the
            // library's refusal counts as one.
            let against = try forged.against.map(targetOf)
            let chunking = try forged.chunking.map { try Chunking(tag: Array($0.utf8)) }
            func needed<Value>(_ value: Value?) throws -> Value {
                guard let value else {
                    throw TestFailure("\(label): the manifest leaves out what this needs")
                }
                return value
            }
            let needs: (Target?, Chunking?, String?, String?) = (against, chunking, forged.name, forged.text)
            switch forged.kind {
            case "file-branch", "folder-branch", "folder-name":
                _ = try needed(needs.0)
            case "file-list-chunking":
                _ = try needed(needs.1)
                // The list is well formed, and does not fit a way of chunking.
                XCTAssertNoThrow(try FileList(decoding: content), "\(label): the list does not read")
            case "root":
                _ = try needed(needs.3)
            default:
                break
            }
            do {
                switch forged.kind {
                case "record":
                    _ = try Record(decoding: content)
                case "file-list":
                    _ = try FileList(decoding: content)
                case "file-list-chunking":
                    try FileList(decoding: content).checkChunking(chunking!)
                case "folder-list":
                    _ = try FolderList(decoding: content)
                case "file-branch":
                    _ = try FileBranch(decoding: content).check(file: against!, chunking: nil)
                case "folder-branch":
                    try FolderBranch(decoding: content).check(folder: against!)
                case "folder-name":
                    _ = try FolderBranch(decoding: content).check(folder: against!, name: try needed(forged.name))
                case "request":
                    _ = try Request(decoding: content)
                case "frame":
                    _ = try Frame(decoding: content)
                case "root":
                    _ = try Root(text: forged.text!)
                default:
                    XCTFail("the manifest offers something as \(forged.kind), which these tests do not know")
                    continue
                }
                XCTFail("taken, and it must be refused: \(label)")
            } catch is TestFailure {
                XCTFail("\(label): the manifest leaves out what this needs")
            } catch {
                // Refused, as it must be.
            }
        }
        for kind in ["record", "file-list", "file-list-chunking", "folder-list", "file-branch", "folder-branch", "folder-name", "request", "frame", "root"] {
            XCTAssertGreaterThan(kinds[kind] ?? 0, 0, "the manifest offers nothing as \(kind)")
        }
    }

    func testEveryCaseOfTheChunkingVectorsIsChunkedWhereTheManifestSays() throws {
        let manifest = try readFastCDCVectors()
        for chunkCase in manifest.cases {
            let name = chunkCase.name
            let data = try inputOf(chunkCase, manifest.cases)
            XCTAssertEqual(data.count, chunkCase.length, "\(name): input length")

            // Cut in memory.
            var end = 0
            var ends: [Int] = []
            var hashes: [String] = []
            for chunk in Chunking.fastCDCv1.cut(data) {
                end += chunk.count
                ends.append(end)
                hashes.append(Hash.of(chunk).hex)
            }
            XCTAssertEqual(ends, chunkCase.boundaries, "\(name): where the chunks end")
            XCTAssertEqual(hashes, chunkCase.chunkSha256, "\(name): the chunks' hashes")

            // Cut by a builder, from memory and as a stream: the file's list
            // names the same chunks, in the same order, with the same lengths.
            let store = MemoryStore()
            let builder = Builder(store: store, chunking: .fastCDCv1)
            let file = try builder.file(bytes: data)
            XCTAssertEqual(try builder.file(from: BytesSource(data, awkward: true)), file, "\(name): as a stream")
            let list = try fileOf(store, file)
            XCTAssertEqual(list.items.map(\.hash.hex), chunkCase.chunkSha256, "\(name): the file's list")
            var listedEnd = 0
            XCTAssertEqual(
                list.items.map { item -> Int in
                    listedEnd += Int(item.length)
                    return listedEnd
                },
                chunkCase.boundaries,
                "\(name): the lengths in the file's list"
            )
            try list.checkChunking(.fastCDCv1)
            // And so the file has the hash that the manifest gives it.
            XCTAssertEqual(file.size, UInt64(data.count), "\(name): the file's size")
            XCTAssertEqual(file.hash.hex, chunkCase.fileHash, "\(name): the file's hash")
        }
    }

    /// A case that edits another one must share with it exactly the chunks the
    /// manifest says it shares. What the base has is worked out here by chunking
    /// the base again, and not taken from the manifest.
    func testAnEditOfTheChunkingVectorsChangesOnlyTheChunksAroundIt() throws {
        let manifest = try readFastCDCVectors()
        var edits = 0
        for chunkCase in manifest.cases where chunkCase.kind == "edit" {
            edits += 1
            guard let base = manifest.cases.first(where: { $0.name == chunkCase.base }) else {
                XCTFail("\(chunkCase.name) edits a case the manifest does not have")
                continue
            }
            let inBase = Set(Chunking.fastCDCv1.cut(try inputOf(base, manifest.cases)).map { Hash.of($0) })
            let shared = Chunking.fastCDCv1.cut(try inputOf(chunkCase, manifest.cases)).map { inBase.contains(Hash.of($0)) }
            XCTAssertEqual(shared, chunkCase.reused, "\(chunkCase.name): which chunks are shared with the base")
            let new = shared.filter { !$0 }.count
            XCTAssertTrue((1...4).contains(new), "\(chunkCase.name): \(new) new chunks")
        }
        XCTAssertGreaterThanOrEqual(edits, 4, "the manifest lists too few edits")
    }
}
