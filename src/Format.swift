// The things a tree is made of, and their exact bytes.
//
// * A chunk is a range of a file's bytes. Its hash is the SHA-256 of those
//   bytes, and nothing else.
// * A file is the list of its chunks, in the file's order.
// * A folder is the list of its entries, sorted by name. An entry holds a
//   name, and the file or folder under it.
// * The record says what a tree's root stands for.
//
// A thing's hash covers what the thing is, and its parent's hash covers where
// it sits. So a file has no name of its own and a chunk has no number of its
// own: the name is in the folder, and the number is the chunk's place in the
// file's list.
//
// A value of one of these types is always well formed. It is checked when it
// is made and when it is read from bytes, and reading is strict: bytes that
// could be written in two ways are read in one way only.
//
// Names are compared by their bytes, as the format orders them, and never as
// Swift compares strings: Swift takes two spellings of one letter, such as
// "\u{E9}" and "e\u{301}", for the same string, and the format takes them for
// two names.

private let fileLeafMark: UInt8 = 0x00
private let folderLeafMark: UInt8 = 0x02
private let fileMark: UInt8 = 0x10
private let folderMark: UInt8 = 0x11
let recordMark: UInt8 = 0x20

/// Whether an entry is a file or a folder.
public enum Kind: UInt8, Hashable, Sendable, Comparable, CustomStringConvertible {
    case file = 1
    case folder = 2

    public static func < (a: Kind, b: Kind) -> Bool {
        a.rawValue < b.rawValue
    }

    public var description: String {
        self == .file ? "file" : "folder"
    }

    static func from(byte: UInt8) throws -> Kind {
        guard let kind = Kind(rawValue: byte) else {
            throw invalid("an entry is neither a file nor a folder")
        }
        return kind
    }
}

/// A file or a folder as the thing above it names it: its kind, its hash, and
/// how many bytes of file content it holds.
public struct Target: Hashable, Sendable {
    public var kind: Kind
    public var hash: Hash
    public var size: UInt64

    public init(kind: Kind, hash: Hash, size: UInt64) {
        self.kind = kind
        self.hash = hash
        self.size = size
    }

    func require(_ kind: Kind) throws {
        guard self.kind == kind else {
            throw invalid(kind == .file
                ? "a folder was given where a file is needed"
                : "a file was given where a folder is needed")
        }
    }
}

/// The text of `bytes` when they are UTF-8, and nil when they are not.
func utf8Text<Bytes: Collection>(_ bytes: Bytes) -> String? where Bytes.Element == UInt8 {
    // Decoding puts U+FFFD in place of what is not UTF-8, so the bytes come
    // back as they were only when all of them are.
    let text = String(decoding: bytes, as: UTF8.self)
    return text.utf8.elementsEqual(bytes) ? text : nil
}

/// Checks a name: 1 to 255 bytes, no `/`, no zero byte, and not `.` or `..`.
public func checkName(_ name: String) throws {
    try checkName(bytes: Array(name.utf8))
}

/// Checks a name given as its UTF-8 bytes.
func checkName(bytes name: [UInt8]) throws {
    let reason: String
    if name.isEmpty {
        reason = "it is empty"
    } else if name.count > Scionic.maxNameBytes {
        reason = "it is longer than 255 bytes"
    } else if name == [0x2E] || name == [0x2E, 0x2E] {
        reason = "it is a dot name"
    } else if name.contains(0x2F) {
        reason = "it holds a slash"
    } else if name.contains(0) {
        reason = "it holds a zero byte"
    } else {
        return
    }
    throw ScionicError.invalidName(name: String(String(decoding: name, as: UTF8.self).prefix(80)), reason: reason)
}

/// A small set of named values, kept beside a name in a folder or in a tree's
/// record. It holds at most 32 values. A value's name is 1 to 64 bytes, and a
/// value is at most 1,024 bytes. The values are kept in the order of their
/// names' bytes.
public struct ExtraData: Hashable, Sendable {
    struct Value: Hashable, Sendable {
        let name: [UInt8]
        let value: [UInt8]
    }

    private(set) var values: [Value] = []

    public init() {}

    /// Where `name` is, or where it would go.
    private func place(of name: [UInt8]) -> (index: Int, found: Bool) {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if bytesLess(values[middle].name, name) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return (low, low < values.count && values[low].name == name)
    }

    /// Sets a value, in place of any value of the same name.
    public mutating func insert<Value: Collection>(_ name: String, _ value: Value) throws where Value.Element == UInt8 {
        let name = Array(name.utf8)
        let value = Array(value)
        guard !name.isEmpty, name.count <= Scionic.maxExtraNameBytes else {
            throw invalid("the name of an extra value is not 1 to 64 bytes")
        }
        guard value.count <= Scionic.maxExtraValueBytes else {
            throw invalid("an extra value is longer than 1,024 bytes")
        }
        let (index, found) = place(of: name)
        if found {
            values[index] = ExtraData.Value(name: name, value: value)
            return
        }
        guard values.count < Scionic.maxExtraValues else {
            throw invalid("extra data holds more than 32 values")
        }
        values.insert(ExtraData.Value(name: name, value: value), at: index)
    }

    /// Sets a value that is text, in place of any value of the same name.
    public mutating func insert(_ name: String, text: String) throws {
        try insert(name, Array(text.utf8))
    }

    /// The same set with one more value.
    public func with<Value: Collection>(_ name: String, _ value: Value) throws -> ExtraData where Value.Element == UInt8 {
        var copy = self
        try copy.insert(name, value)
        return copy
    }

    /// The same set with one more value that is text.
    public func with(_ name: String, text: String) throws -> ExtraData {
        try with(name, Array(text.utf8))
    }

    public func get(_ name: String) -> [UInt8]? {
        get(bytes: Array(name.utf8))
    }

    func get(bytes name: [UInt8]) -> [UInt8]? {
        let (index, found) = place(of: name)
        return found ? values[index].value : nil
    }

    /// A value as text, when it is UTF-8.
    public func text(_ name: String) -> String? {
        get(name).flatMap(utf8Text)
    }

    @discardableResult
    public mutating func remove(_ name: String) -> [UInt8]? {
        let (index, found) = place(of: Array(name.utf8))
        return found ? values.remove(at: index).value : nil
    }

    public var count: Int {
        values.count
    }

    public var isEmpty: Bool {
        values.isEmpty
    }

    /// The values, in the order of their names' bytes.
    public var all: [(name: String, value: [UInt8])] {
        values.map { (String(decoding: $0.name, as: UTF8.self), $0.value) }
    }

    var encodedCount: Int {
        values.reduce(2) { $0 + 4 + $1.name.count + $1.value.count }
    }

    func encode(into out: inout [UInt8]) {
        out.appendU16(UInt16(values.count))
        for value in values {
            out.appendU16(UInt16(value.name.count))
            out.append(contentsOf: value.name)
            out.appendU16(UInt16(value.value.count))
            out.append(contentsOf: value.value)
        }
    }

    static func decode(_ reader: inout ByteReader) throws -> ExtraData {
        let count = Int(try reader.u16())
        guard count <= Scionic.maxExtraValues else {
            throw invalid("extra data holds more than 32 values")
        }
        var extra = ExtraData()
        extra.values.reserveCapacity(count)
        for _ in 0..<count {
            let nameCount = Int(try reader.u16())
            guard nameCount >= 1, nameCount <= Scionic.maxExtraNameBytes else {
                throw invalid("the name of an extra value is not 1 to 64 bytes")
            }
            let name = Array(try reader.take(nameCount))
            if let previous = extra.values.last, !bytesLess(previous.name, name) {
                throw invalid("extra values are not in the order of their names, or a name is there twice")
            }
            guard utf8Text(name) != nil else {
                throw invalid("the name of an extra value is not UTF-8")
            }
            let valueCount = Int(try reader.u16())
            guard valueCount <= Scionic.maxExtraValueBytes else {
                throw invalid("an extra value is longer than 1,024 bytes")
            }
            extra.values.append(ExtraData.Value(name: name, value: Array(try reader.take(valueCount))))
        }
        return extra
    }
}

/// One item of a file's list: a chunk's hash, and how many bytes it holds.
public struct ChunkRef: Hashable, Sendable {
    public var hash: Hash
    public var length: UInt32

    /// An item as it is given. A file's list holds it to the rules.
    public init(hash: Hash, length: UInt32) {
        self.hash = hash
        self.length = length
    }

    /// The item for a chunk with these bytes. A chunk holds 1 byte to 8 MiB.
    public static func of(_ bytes: [UInt8]) throws -> ChunkRef {
        try bytes.withUnsafeBytes { try of($0) }
    }

    /// The item for a chunk with these bytes. A chunk holds 1 byte to 8 MiB.
    public static func of(_ bytes: UnsafeRawBufferPointer) throws -> ChunkRef {
        guard bytes.count >= 1, bytes.count <= Scionic.maxChunkBytes else {
            throw invalid("a chunk does not hold 1 byte to 8 MiB")
        }
        return ChunkRef(hash: sha256(bytes), length: UInt32(bytes.count))
    }

    func check() throws {
        guard length >= 1, Int(length) <= Scionic.maxChunkBytes else {
            throw invalid("a chunk does not hold 1 byte to 8 MiB")
        }
    }

    /// Whether `bytes` are the chunk this item names: of its length, and with
    /// its hash.
    public func matches(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { matches($0) }
    }

    /// Whether `bytes` are the chunk this item names.
    public func matches(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.count == Int(length) && sha256(bytes) == hash
    }

    func encode(into out: inout [UInt8]) {
        out.append(hash)
        out.appendU32(length)
    }

    static func decode(_ reader: inout ByteReader) throws -> ChunkRef {
        let item = ChunkRef(hash: try reader.hash(), length: try reader.u32())
        try item.check()
        return item
    }

    /// The item's leaf in its file's tree.
    var leaf: Node {
        let digest = withUnsafeTemporaryAllocation(byteCount: 37, alignment: 8) { buffer -> Hash in
            var out = RawWriter(buffer)
            out.u8(fileLeafMark)
            out.hash(hash)
            out.u32(length)
            return sha256(UnsafeRawBufferPointer(buffer))
        }
        return Node(hash: digest, size: UInt64(length))
    }
}

/// One entry of a folder: a name, the file or folder under it, and extra data.
public struct Entry: Hashable, Sendable {
    /// The name's bytes, which are UTF-8.
    public let nameBytes: [UInt8]
    public let target: Target
    public let extra: ExtraData

    public init(name: String, target: Target, extra: ExtraData = ExtraData()) throws {
        let bytes = Array(name.utf8)
        try checkName(bytes: bytes)
        self.init(checked: bytes, target: target, extra: extra)
    }

    /// An entry whose name is given as its bytes, which must be UTF-8.
    public init(nameBytes: [UInt8], target: Target, extra: ExtraData = ExtraData()) throws {
        guard utf8Text(nameBytes) != nil else {
            throw invalid("a name is not UTF-8")
        }
        try checkName(bytes: nameBytes)
        self.init(checked: nameBytes, target: target, extra: extra)
    }

    init(checked nameBytes: [UInt8], target: Target, extra: ExtraData) {
        self.nameBytes = nameBytes
        self.target = target
        self.extra = extra
    }

    public var name: String {
        String(decoding: nameBytes, as: UTF8.self)
    }

    public var kind: Kind {
        target.kind
    }

    /// How many bytes of file content are under this entry.
    public var size: UInt64 {
        target.size
    }

    public var hash: Hash {
        target.hash
    }

    /// How many bytes the entry takes in its folder's list.
    public var encodedCount: Int {
        1 + 8 + 32 + 2 + nameBytes.count + extra.encodedCount
    }

    func encode(into out: inout [UInt8]) {
        out.append(target.kind.rawValue)
        out.appendU64(target.size)
        out.append(target.hash)
        out.appendU16(UInt16(nameBytes.count))
        out.append(contentsOf: nameBytes)
        extra.encode(into: &out)
    }

    static func decode(_ reader: inout ByteReader) throws -> Entry {
        let kind = try Kind.from(byte: reader.u8())
        let size = try reader.u64()
        let hash = try reader.hash()
        let nameCount = Int(try reader.u16())
        let name = Array(try reader.take(nameCount))
        guard utf8Text(name) != nil else {
            throw invalid("a name is not UTF-8")
        }
        try checkName(bytes: name)
        let extra = try ExtraData.decode(&reader)
        return Entry(checked: name, target: Target(kind: kind, hash: hash, size: size), extra: extra)
    }

    /// The entry's leaf in its folder's tree.
    var leaf: Node {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1 + encodedCount)
        bytes.append(folderLeafMark)
        encode(into: &bytes)
        return Node(hash: sha256(bytes), size: target.size)
    }
}

private func ownerHash(_ mark: UInt8, _ count: UInt64, _ size: UInt64, _ list: Hash) -> Hash {
    withUnsafeTemporaryAllocation(byteCount: 49, alignment: 8) { buffer -> Hash in
        var out = RawWriter(buffer)
        out.u8(mark)
        out.u64(count)
        out.u64(size)
        out.hash(list)
        return sha256(UnsafeRawBufferPointer(buffer))
    }
}

/// The hash of a file with `count` chunks and `size` bytes, whose list's tree
/// has `list` on top.
public func fileHash(count: UInt64, size: UInt64, list: Hash) -> Hash {
    ownerHash(fileMark, count, size, list)
}

/// The hash of a folder with `count` entries and `size` bytes of file content,
/// whose list's tree has `list` on top.
public func folderHash(count: UInt64, size: UInt64, list: Hash) -> Hash {
    ownerHash(folderMark, count, size, list)
}

/// Holds a rebuilt top against the file or folder it should be the top of.
private func confirm(_ target: Target, _ count: UInt64, _ top: Node) throws {
    let what: String
    let hash: Hash
    switch target.kind {
    case .file:
        what = "a file's list"
        hash = fileHash(count: count, size: top.size, list: top.hash)
    case .folder:
        what = "a folder's list"
        hash = folderHash(count: count, size: top.size, list: top.hash)
    }
    guard top.size == target.size else {
        throw ScionicError.sizeMismatch(what: what, expected: target.size, actual: top.size)
    }
    guard hash == target.hash else {
        throw ScionicError.hashMismatch(what: what)
    }
}

/// The first place in `0..<count` at which `isAfter` holds, for a test that
/// holds from some place on and never before it.
func partitionPoint(_ count: Int, _ isAfter: (Int) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
        let middle = low + (high - low) / 2
        if isAfter(middle) {
            high = middle
        } else {
            low = middle + 1
        }
    }
    return low
}

// MARK: - A file

/// A file: the list of its chunks, in the file's order.
public struct FileList: Hashable, Sendable {
    public let items: [ChunkRef]
    /// How many bytes the file holds.
    public let size: UInt64
    /// The file's hash. It covers the chunks, their order, how many there are
    /// and the size, and nothing about where the file sits.
    public let hash: Hash

    /// The file with these chunks, in this order. A chunk that occurs twice is
    /// listed twice. No chunks at all is the empty file.
    public init(items: [ChunkRef]) throws {
        var leaves: [Leaf] = []
        leaves.reserveCapacity(items.count)
        for item in items {
            try item.check()
            leaves.append(Leaf(node: item.leaf))
        }
        let top = try topOf(.file, leaves)
        self.init(items: items, size: top.size, hash: fileHash(count: UInt64(items.count), size: top.size, list: top.hash))
    }

    private init(items: [ChunkRef], size: UInt64, hash: Hash) {
        self.items = items
        self.size = size
        self.hash = hash
    }

    /// Reads the items of a whole list: 36 bytes for each chunk.
    static func items(of bytes: [UInt8]) throws -> [ChunkRef] {
        guard bytes.count % Scionic.listItemBytes == 0 else {
            throw invalid("a file's list is not a whole number of items")
        }
        var reader = ByteReader(bytes, what: "a file's list")
        var items: [ChunkRef] = []
        items.reserveCapacity(bytes.count / Scionic.listItemBytes)
        while !reader.isEmpty {
            items.append(try ChunkRef.decode(&reader))
        }
        return items
    }

    /// Reads a whole list: 36 bytes for each chunk.
    public init(decoding bytes: [UInt8]) throws {
        try self.init(items: FileList.items(of: bytes))
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(items.count * Scionic.listItemBytes)
        for item in items {
            item.encode(into: &out)
        }
        return out
    }

    /// How many chunks the file has.
    public var count: UInt64 {
        UInt64(items.count)
    }

    public var target: Target {
        Target(kind: .file, hash: hash, size: size)
    }

    /// How many bytes the list takes.
    public var encodedCount: UInt64 {
        UInt64(items.count) * UInt64(Scionic.listItemBytes)
    }

    /// Whether every chunk has a length that `chunking` gives.
    public func checkChunking(_ chunking: Chunking) throws {
        try chunking.checkCount(size: size, count: count)
        let last = items.count - 1
        for (index, item) in items.enumerated() {
            try chunking.checkLength(item.length, isLast: index == last)
        }
    }

    var leaves: [Leaf] {
        items.map { Leaf(node: $0.leaf) }
    }

    /// Shows chunks `start` up to, not including, `end`. This hashes the whole
    /// list each time: keep an `OpenFile` to show many parts.
    public func open(start: UInt64, end: UInt64) throws -> FileBranch {
        try open(with: ListTree(kind: .file, leaves: leaves), start: start, end: end)
    }

    func open(with tree: ListTree, start: UInt64, end: UInt64) throws -> FileBranch {
        let carried = try tree.open(start: start, end: end)
        return FileBranch(count: count, start: start, items: Array(items[Int(start)..<Int(end)]), carried: carried)
    }

    /// A list as it is said to be, with no hashing: for an `OpenFile` that
    /// hashed it already.
    static func hashed(items: [ChunkRef], top: Node) -> FileList {
        FileList(items: items, size: top.size, hash: fileHash(count: UInt64(items.count), size: top.size, list: top.hash))
    }
}

/// A file's list with its tree kept, for showing many parts of it, and for
/// finding the chunks that hold a stretch of bytes.
public struct OpenFile: Sendable {
    public let list: FileList
    let tree: ListTree
    /// Where each chunk starts, and after the last one the file's size.
    let starts: [UInt64]

    public init(_ list: FileList) throws {
        self.init(list: list, tree: try ListTree(kind: .file, leaves: list.leaves))
    }

    /// Reads a whole list as `FileList(decoding:)` does, and keeps its tree.
    /// The list is hashed once for both.
    public init(decoding bytes: [UInt8]) throws {
        let items = try FileList.items(of: bytes)
        let tree = try ListTree(kind: .file, leaves: items.map { Leaf(node: $0.leaf) })
        self.init(list: FileList.hashed(items: items, top: try tree.top()), tree: tree)
    }

    private init(list: FileList, tree: ListTree) {
        var starts: [UInt64] = []
        starts.reserveCapacity(list.items.count + 1)
        var at: UInt64 = 0
        for item in list.items {
            starts.append(at)
            at += UInt64(item.length)
        }
        starts.append(at)
        self.list = list
        self.tree = tree
        self.starts = starts
    }

    /// The byte at which chunk `index` starts. The count gives the size.
    public func startOf(_ index: UInt64) -> UInt64? {
        index < UInt64(starts.count) ? starts[Int(index)] : nil
    }

    /// The chunks that hold the `length` bytes from `offset`: the first one's
    /// number, and the number after the last one. The stretch must lie inside
    /// the file and hold at least one byte.
    public func chunksFor(offset: UInt64, length: UInt64) throws -> (start: UInt64, end: UInt64) {
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, length > 0, end <= list.size else {
            throw invalid("a stretch of bytes is outside the file")
        }
        // Every chunk holds a byte, so the starts ascend and each is found.
        let first = partitionPoint(starts.count) { starts[$0] > offset } - 1
        let after = partitionPoint(starts.count) { starts[$0] >= end }
        return (UInt64(first), UInt64(after))
    }

    /// Shows chunks `start` up to, not including, `end`.
    public func open(start: UInt64, end: UInt64) throws -> FileBranch {
        try list.open(with: tree, start: start, end: end)
    }

    /// Shows the chunks that hold the `length` bytes from `offset`.
    public func openBytes(offset: UInt64, length: UInt64) throws -> FileBranch {
        let (start, end) = try chunksFor(offset: offset, length: length)
        return try open(start: start, end: end)
    }
}

/// A branch of a file's list, with the nodes that stand for the rest of it.
public struct FileBranch: Hashable, Sendable {
    /// How many chunks the whole file is said to have.
    public let count: UInt64
    /// The number of the first chunk shown.
    public let start: UInt64
    public let items: [ChunkRef]
    public let carried: [Carried]

    init(count: UInt64, start: UInt64, items: [ChunkRef], carried: [Carried]) {
        self.count = count
        self.start = start
        self.items = items
        self.carried = carried
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(22 + items.count * Scionic.listItemBytes + carried.count * 40)
        out.appendU64(count)
        out.appendU64(start)
        out.appendU32(UInt32(items.count))
        for item in items {
            item.encode(into: &out)
        }
        out.appendU16(UInt16(carried.count))
        for node in carried {
            out.append(node.node.hash)
            out.appendU64(node.node.size)
        }
        return out
    }

    public init(decoding bytes: [UInt8]) throws {
        var reader = ByteReader(bytes, what: "a branch of a file's list")
        let (count, start, shown) = try branchHeader(&reader)
        guard shown != 0, reader.remaining / Scionic.listItemBytes >= shown else {
            throw invalid("a branch of a file's list is cut short, or shows nothing")
        }
        var items: [ChunkRef] = []
        items.reserveCapacity(shown)
        for _ in 0..<shown {
            items.append(try ChunkRef.decode(&reader))
        }
        var carried: [Carried] = []
        for _ in 0..<(try carriedCount(&reader)) {
            carried.append(Carried(node: Node(hash: try reader.hash(), size: try reader.u64())))
        }
        try reader.finish()
        self.init(count: count, start: start, items: items, carried: carried)
    }

    /// Checks the branch against the file it is said to be a part of, and gives
    /// the byte of the file at which the branch starts. With a way of chunking,
    /// the chunks' lengths are held to it too.
    @discardableResult
    public func check(file: Target, chunking: Chunking?) throws -> UInt64 {
        try file.require(.file)
        if let chunking {
            try chunking.checkCount(size: file.size, count: count)
            for (place, item) in zip(start..., items) {
                try chunking.checkLength(item.length, isLast: place + 1 == count)
            }
        }
        let shown = try checkBranch(
            kind: .file,
            count: count,
            start: start,
            opened: items.map { Leaf(node: $0.leaf) },
            carried: carried
        )
        try confirm(file, count, shown.top)
        return shown.offset
    }
}

/// What every branch starts with: how many items the whole list has, the place
/// of the first one shown, and how many are shown.
private func branchHeader(_ reader: inout ByteReader) throws -> (count: UInt64, start: UInt64, shown: Int) {
    let count = try reader.u64()
    let start = try reader.u64()
    let shown = try reader.u32()
    let (end, overflow) = start.addingReportingOverflow(UInt64(shown))
    guard count <= Scionic.maxListItems, !overflow, end <= count else {
        throw invalid("a branch lies outside its list")
    }
    return (count, start, Int(shown))
}

private func carriedCount(_ reader: inout ByteReader) throws -> Int {
    let count = Int(try reader.u16())
    guard count <= Scionic.maxCarriedNodes else {
        throw invalid("a branch carries more nodes than any list needs")
    }
    return count
}

// MARK: - A folder

/// A folder: the list of its entries, sorted by name, with no name twice.
public struct FolderList: Hashable, Sendable {
    public let entries: [Entry]
    /// How many bytes of file content are under the folder.
    public let size: UInt64
    /// The folder's hash. It covers every entry: its name, its kind, its size,
    /// its hash and its extra data. It does not cover a name for the folder
    /// itself.
    public let hash: Hash
    /// How many bytes the list takes.
    public let encodedCount: UInt64

    /// The folder with these entries. They must be in the order of their names'
    /// bytes, with no name twice. No entries is the empty folder.
    public init(entries: [Entry]) throws {
        let top = try topOf(.folder, entries.map { Leaf(node: $0.leaf, name: $0.nameBytes) })
        self.init(entries: entries, top: top)
    }

    private init(entries: [Entry], top: Node) {
        self.entries = entries
        self.size = top.size
        self.hash = folderHash(count: UInt64(entries.count), size: top.size, list: top.hash)
        self.encodedCount = entries.reduce(0) { $0 + UInt64($1.encodedCount) }
    }

    /// Reads the entries of a whole list, one after another.
    static func entries(of bytes: [UInt8]) throws -> [Entry] {
        var reader = ByteReader(bytes, what: "a folder's list")
        var entries: [Entry] = []
        while !reader.isEmpty {
            entries.append(try Entry.decode(&reader))
        }
        return entries
    }

    /// Reads a whole list: its entries, one after another.
    public init(decoding bytes: [UInt8]) throws {
        try self.init(entries: FolderList.entries(of: bytes))
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Int(encodedCount))
        for entry in entries {
            entry.encode(into: &out)
        }
        return out
    }

    /// How many entries the folder has.
    public var count: UInt64 {
        UInt64(entries.count)
    }

    public var target: Target {
        Target(kind: .folder, hash: hash, size: size)
    }

    /// The entry with this name.
    public func get(_ name: String) -> Entry? {
        get(bytes: Array(name.utf8))
    }

    /// The entry with this name, given as its bytes.
    public func get(bytes name: [UInt8]) -> Entry? {
        let index = partitionPoint(entries.count) { !bytesLess(entries[$0].nameBytes, name) }
        return index < entries.count && entries[index].nameBytes == name ? entries[index] : nil
    }

    /// The one place where `name` can be: that of the last entry whose name
    /// does not sort after it, or the first place. An empty folder has none.
    public func placeOf(_ name: String) -> UInt64? {
        placeOf(bytes: Array(name.utf8))
    }

    func placeOf(bytes name: [UInt8]) -> UInt64? {
        if entries.isEmpty {
            return nil
        }
        let notAfter = partitionPoint(entries.count) { bytesLess(name, entries[$0].nameBytes) }
        return UInt64(max(notAfter - 1, 0))
    }

    var leaves: [Leaf] {
        entries.map { Leaf(node: $0.leaf, name: $0.nameBytes) }
    }

    /// Shows entries `start` up to, not including, `end`. This hashes the whole
    /// list each time: keep an `OpenFolder` to show many parts.
    public func open(start: UInt64, end: UInt64) throws -> FolderBranch {
        try open(with: ListTree(kind: .folder, leaves: leaves), start: start, end: end)
    }

    /// Shows the entry at the one place where `name` can be. It answers whether
    /// the folder has the name, whichever way the answer falls.
    public func openName(_ name: String) throws -> FolderBranch {
        try openName(with: ListTree(kind: .folder, leaves: leaves), name: Array(name.utf8))
    }

    func open(with tree: ListTree, start: UInt64, end: UInt64) throws -> FolderBranch {
        let carried = try tree.open(start: start, end: end)
        return FolderBranch(count: count, start: start, entries: Array(entries[Int(start)..<Int(end)]), carried: carried)
    }

    func openName(with tree: ListTree, name: [UInt8]) throws -> FolderBranch {
        try checkName(bytes: name)
        guard let place = placeOf(bytes: name) else {
            return .empty
        }
        return try open(with: tree, start: place, end: place + 1)
    }

    /// A list as it is said to be, with no hashing: for an `OpenFolder` that
    /// hashed it already.
    static func hashed(entries: [Entry], top: Node) -> FolderList {
        FolderList(entries: entries, top: top)
    }
}

/// A folder's list with its tree kept, for showing many parts of it.
public struct OpenFolder: Sendable {
    public let list: FolderList
    let tree: ListTree

    public init(_ list: FolderList) throws {
        self.list = list
        self.tree = try ListTree(kind: .folder, leaves: list.leaves)
    }

    /// Reads a whole list as `FolderList(decoding:)` does, and keeps its tree.
    /// The list is hashed once for both.
    public init(decoding bytes: [UInt8]) throws {
        let entries = try FolderList.entries(of: bytes)
        let tree = try ListTree(kind: .folder, leaves: entries.map { Leaf(node: $0.leaf, name: $0.nameBytes) })
        self.list = FolderList.hashed(entries: entries, top: try tree.top())
        self.tree = tree
    }

    /// Shows entries `start` up to, not including, `end`.
    public func open(start: UInt64, end: UInt64) throws -> FolderBranch {
        try list.open(with: tree, start: start, end: end)
    }

    /// Shows the entry at the one place where `name` can be.
    public func openName(_ name: String) throws -> FolderBranch {
        try list.openName(with: tree, name: Array(name.utf8))
    }

    /// Shows the entry at the one place where `name`, given as its bytes, can be.
    func openName(bytes name: [UInt8]) throws -> FolderBranch {
        try list.openName(with: tree, name: name)
    }
}

/// A branch of a folder's list, with the nodes that stand for the rest of it.
/// A branch of an empty folder shows nothing, and carries nothing.
public struct FolderBranch: Hashable, Sendable {
    /// How many entries the whole folder is said to have.
    public let count: UInt64
    /// The place of the first entry shown.
    public let start: UInt64
    public let entries: [Entry]
    public let carried: [Carried]

    init(count: UInt64, start: UInt64, entries: [Entry], carried: [Carried]) {
        self.count = count
        self.start = start
        self.entries = entries
        self.carried = carried
    }

    /// The branch of an empty folder: it shows nothing, and carries nothing.
    static let empty = FolderBranch(count: 0, start: 0, entries: [], carried: [])

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.appendU64(count)
        out.appendU64(start)
        out.appendU32(UInt32(entries.count))
        for entry in entries {
            entry.encode(into: &out)
        }
        out.appendU16(UInt16(carried.count))
        for node in carried {
            out.append(node.node.hash)
            out.appendU64(node.node.size)
            out.appendU16(UInt16(node.firstName.count))
            out.append(contentsOf: node.firstName)
        }
        return out
    }

    public init(decoding bytes: [UInt8]) throws {
        var reader = ByteReader(bytes, what: "a branch of a folder's list")
        let (count, start, shown) = try branchHeader(&reader)
        if (shown == 0) != (count == 0) {
            throw invalid("a branch of a folder's list shows nothing")
        }
        // An entry takes 45 bytes at least, so a count is held to the bytes.
        guard reader.remaining / 45 >= shown else {
            throw invalid("a branch of a folder's list is cut short")
        }
        var entries: [Entry] = []
        entries.reserveCapacity(shown)
        for _ in 0..<shown {
            entries.append(try Entry.decode(&reader))
        }
        var carried: [Carried] = []
        for index in 0..<(try carriedCount(&reader)) {
            let node = Node(hash: try reader.hash(), size: try reader.u64())
            let nameCount = Int(try reader.u16())
            // The first carried node of a branch that does not start the list
            // is the node that begins the list. No fork hashes a name for it,
            // so it comes with none. Every other one comes with a name.
            let beginsTheList = index == 0 && start > 0
            if beginsTheList != (nameCount == 0) {
                throw invalid(beginsTheList
                    ? "the carried node that begins a folder's list has a name"
                    : "a carried node of a folder's list has no name")
            }
            guard nameCount <= Scionic.maxNameBytes else {
                throw invalid("a carried name is longer than 255 bytes")
            }
            carried.append(Carried(node: node, firstName: Array(try reader.take(nameCount))))
        }
        try reader.finish()
        if count == 0 && !carried.isEmpty {
            throw invalid("a branch of an empty folder carries nodes")
        }
        self.init(count: count, start: start, entries: entries, carried: carried)
    }

    private var leaves: [Leaf] {
        entries.map { Leaf(node: $0.leaf, name: $0.nameBytes) }
    }

    /// Checks the branch against the folder it is said to be a part of. Every
    /// entry shown is then an entry of that folder, at the place where a search
    /// for its name ends.
    public func check(folder: Target) throws {
        try folder.require(.folder)
        if count == 0 {
            guard entries.isEmpty, carried.isEmpty, start == 0 else {
                throw invalid("a branch of an empty folder shows something")
            }
            try confirm(folder, 0, .emptyList)
            return
        }
        let shown = try checkBranch(kind: .folder, count: count, start: start, opened: leaves, carried: carried)
        try confirm(folder, count, shown.top)
    }

    /// Checks the branch as the answer to "what is under `name` in this
    /// folder". It gives the entry, or nil when the folder has no entry of that
    /// name. Either answer is proven: the branch must show the one place where
    /// the name can be.
    public func check(folder: Target, name: String) throws -> Entry? {
        try check(folder: folder, nameBytes: Array(name.utf8))
    }

    func check(folder: Target, nameBytes name: [UInt8]) throws -> Entry? {
        try checkName(bytes: name)
        try folder.require(.folder)
        if count == 0 {
            try check(folder: folder)
            return nil
        }
        guard entries.count == 1, let entry = entries.first else {
            throw invalid("a name is answered by one entry, and no more")
        }
        let (shown, present) = try checkLookup(
            count: count,
            index: start,
            entry: Leaf(node: entry.leaf, name: entry.nameBytes),
            name: name,
            carried: carried
        )
        try confirm(folder, count, shown.top)
        return present ? entry : nil
    }
}

// MARK: - The record

/// What a tree says about itself as a whole: how much a store has to keep for
/// it. Each counts a thing once, however often the tree uses it.
public struct Totals: Hashable, Sendable {
    /// How many different chunks the tree has.
    public var chunks: UInt64
    /// How many bytes those chunks hold.
    public var chunkBytes: UInt64
    /// How many bytes the lists of its different files and folders take.
    public var listBytes: UInt64

    public init(chunks: UInt64 = 0, chunkBytes: UInt64 = 0, listBytes: UInt64 = 0) {
        self.chunks = chunks
        self.chunkBytes = chunkBytes
        self.listBytes = listBytes
    }
}

/// A tree's record: the file or folder on top, the tree's totals, and its
/// extra data. The hash of the record is the tree's root.
public struct Record: Hashable, Sendable {
    /// The file or folder on top of the tree.
    public let top: Target
    public let totals: Totals
    public let extra: ExtraData
    /// How the tree's files were chunked.
    public let chunking: Chunking

    /// The record of a tree with `top` on top. How the tree was chunked is
    /// written into the extra data, in place of anything the caller put under
    /// that name.
    public init(top: Target, totals: Totals, chunking: Chunking, extra: ExtraData = ExtraData()) throws {
        var extra = extra
        extra.remove(Scionic.chunkingKey)
        try extra.insert(Scionic.chunkingKey, text: chunking.tag)
        try checkTotals(top, totals)
        self.top = top
        self.totals = totals
        self.extra = extra
        self.chunking = chunking
    }

    public init(decoding bytes: [UInt8]) throws {
        var reader = ByteReader(bytes, what: "a record")
        guard try reader.u8() == recordMark else {
            throw invalid("a record does not start with its mark")
        }
        let kind = try Kind.from(byte: reader.u8())
        let size = try reader.u64()
        let hash = try reader.hash()
        let totals = Totals(chunks: try reader.u64(), chunkBytes: try reader.u64(), listBytes: try reader.u64())
        let extra = try ExtraData.decode(&reader)
        try reader.finish()
        guard let tag = extra.get(Scionic.chunkingKey) else {
            throw invalid("a record does not say how the tree was chunked")
        }
        let chunking = try Chunking(tag: tag)
        let top = Target(kind: kind, hash: hash, size: size)
        try checkTotals(top, totals)
        self.top = top
        self.totals = totals
        self.extra = extra
        self.chunking = chunking
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(66 + extra.encodedCount)
        out.append(recordMark)
        out.append(top.kind.rawValue)
        out.appendU64(top.size)
        out.append(top.hash)
        out.appendU64(totals.chunks)
        out.appendU64(totals.chunkBytes)
        out.appendU64(totals.listBytes)
        extra.encode(into: &out)
        return out
    }

    /// The tree's root: the hash of the record.
    public var root: Root {
        Root.of(record: encode())
    }
}

/// What must hold between a record's numbers in any tree. Whether the totals
/// are right is checked against the whole tree.
private func checkTotals(_ top: Target, _ totals: Totals) throws {
    let (most, mostOverflow) = totals.chunks.multipliedReportingOverflow(by: UInt64(Scionic.maxChunkBytes))
    let (least, leastOverflow) = totals.chunks.multipliedReportingOverflow(by: UInt64(Scionic.listItemBytes))
    let fits = totals.chunks <= totals.chunkBytes
        && totals.chunkBytes <= top.size
        && (mostOverflow || totals.chunkBytes <= most)
        && (!leastOverflow && totals.listBytes >= least)
        && (top.kind == .folder || totals.listBytes % UInt64(Scionic.listItemBytes) == 0)
    guard fits else {
        throw invalid("a record's totals cannot belong to any tree")
    }
}
