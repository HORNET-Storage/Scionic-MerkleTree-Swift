// The classic tree over a list.
//
// A file is a list of chunks and a folder is a list of entries. This turns a
// list into the one hash that its owner is known by, shows a part of a list
// together with the nodes that stand for the rest, and checks such a showing.
//
// The rule, in full:
//
// * a leaf stands for one item of the list: the caller hashes the item, and
//   says how many bytes of file content it holds;
// * a fork joins two halves: its hash covers each half's hash, its size and
//   the number of its items, and in a folder's tree the first name of its
//   right half; its size is the two sizes added;
// * a list of more than one item is halved at the largest power of two that
//   is less than its length.
//
// So the shape of a tree follows from the number of its items alone, and the
// hash on top covers that number: a list cannot be passed off as a longer or a
// shorter one. Nothing is padded and nothing is repeated, and a place beyond
// the count does not exist. Forks are hashed from a mark of their own, so a
// fork cannot be shown as a leaf.

private let fileFork: UInt8 = 0x01
private let folderFork: UInt8 = 0x03

/// What a list is a list of.
public enum ListKind: Hashable, Sendable {
    /// A file's chunks, in the file's order.
    case file
    /// A folder's entries, sorted by name. Its forks record names.
    case folder
}

/// A node of a list's tree: its hash, and the bytes of file content under it.
public struct Node: Hashable, Sendable {
    public var hash: Hash
    public var size: UInt64

    public init(hash: Hash, size: UInt64) {
        self.hash = hash
        self.size = size
    }

    /// What an empty list has in place of a tree.
    public static let emptyList = Node(hash: .zero, size: 0)
}

/// One item of a list as its tree sees it: the item's leaf, and for a
/// folder's list the entry's name. A file's list has no names.
public struct Leaf: Hashable, Sendable {
    public var node: Node
    public var name: [UInt8]

    public init(node: Node, name: [UInt8] = []) {
        self.node = node
        self.name = name
    }
}

/// A node sent in place of the items under it. In a folder's tree it comes
/// with the first name under it, which the fork above it hashes as the first
/// name of its right half.
///
/// One carried node is in no right half: the one that begins with the list's
/// first item. No hash covers a name for it, so it has none, and a checker
/// takes none. That way every byte of a branch is covered by the hash it is
/// held against.
public struct Carried: Hashable, Sendable {
    public var node: Node
    public var firstName: [UInt8]

    public init(node: Node, firstName: [UInt8] = []) {
        self.node = node
        self.firstName = firstName
    }
}

/// What a branch shows, once it is rebuilt: the node on top of the list, to
/// hold against the hash and size the list is known by, and how many bytes of
/// file content come before the first item shown.
public struct Shown: Hashable, Sendable {
    public var top: Node
    public var offset: UInt64
}

/// Where a list of `width` items is halved: the largest power of two below it.
@inline(__always)
func split(_ width: UInt64) -> UInt64 {
    precondition(width >= 2)
    return 1 << UInt64(63 - (width - 1).leadingZeroBitCount)
}

/// Joins two halves. `leftItems` and `rightItems` say how many items of the
/// list are under each.
func fork(
    _ kind: ListKind,
    _ left: Node,
    _ leftItems: UInt64,
    _ right: Node,
    _ rightItems: UInt64,
    _ rightFirstName: [UInt8]
) throws -> Node {
    let (size, overflow) = left.size.addingReportingOverflow(right.size)
    if overflow {
        throw ScionicError.sizeOverflow(field: "list size")
    }
    let name = kind == .folder ? rightFirstName : []
    let hash = withUnsafeTemporaryAllocation(byteCount: 97 + name.count, alignment: 8) { buffer -> Hash in
        var out = RawWriter(buffer)
        out.u8(kind == .file ? fileFork : folderFork)
        out.hash(left.hash)
        out.u64(left.size)
        out.u64(leftItems)
        out.hash(right.hash)
        out.u64(right.size)
        out.u64(rightItems)
        out.bytes(name)
        return sha256(UnsafeRawBufferPointer(buffer))
    }
    return Node(hash: hash, size: size)
}

/// A whole list has to be short enough, and a folder's has to be sorted by
/// name with no name twice.
private func checkList(_ kind: ListKind, _ leaves: [Leaf]) throws {
    if UInt64(leaves.count) > Scionic.maxListItems {
        throw invalid("a list holds more items than the format allows")
    }
    if kind == .folder && !namesAscend(leaves) {
        throw invalid("a folder's entries are not sorted by name, or a name is there twice")
    }
}

private func namesAscend(_ leaves: [Leaf]) -> Bool {
    var index = 1
    while index < leaves.count {
        if !bytesLess(leaves[index - 1].name, leaves[index].name) {
            return false
        }
        index += 1
    }
    return true
}

/// The node on top of a whole list. An empty list gives `Node.emptyList`.
public func topOf(_ kind: ListKind, _ leaves: [Leaf]) throws -> Node {
    try checkList(kind, leaves)
    return try topUnchecked(kind, leaves)
}

private func topUnchecked(_ kind: ListKind, _ leaves: [Leaf]) throws -> Node {
    // Two whole trees of one width are joined as soon as they stand side by
    // side, so the stack holds one tree for each 1 bit of the count so far.
    // Each is kept with the place of its first item and its width.
    var stack: [(node: Node, first: Int, width: Int)] = []
    for index in leaves.indices {
        var right = (node: leaves[index].node, first: index, width: 1)
        while let left = stack.last, left.width == right.width {
            stack.removeLast()
            let node = try fork(kind, left.node, UInt64(left.width), right.node, UInt64(right.width), leaves[right.first].name)
            right = (node: node, first: left.first, width: left.width * 2)
        }
        stack.append(right)
    }
    // What is left joins from the right: each is the left half of all after it.
    guard var top = stack.popLast() else {
        return .emptyList
    }
    while let left = stack.popLast() {
        let node = try fork(kind, left.node, UInt64(left.width), top.node, UInt64(top.width), leaves[top.first].name)
        top = (node: node, first: left.first, width: left.width + top.width)
    }
    return top.node
}

/// A list's tree kept whole, for showing parts of it. It keeps its own copy of
/// the leaves, and of the names in a folder's list.
public struct ListTree: Sendable {
    let kind: ListKind
    let leaves: [Node]
    /// A folder's names, in the list's order. Empty for a file's list.
    let names: [[UInt8]]
    /// `levels[j]` holds, in order, the nodes over `2^(j + 1)` items each.
    let levels: [[Node]]

    public init(kind: ListKind, leaves: [Leaf]) throws {
        try checkList(kind, leaves)
        try self.init(unchecked: kind, leaves: leaves)
    }

    /// A tree over a list that is not held to the rules: for tests that show
    /// what a list put together out of order can and cannot prove.
    init(unchecked kind: ListKind, leaves: [Leaf]) throws {
        var levels: [[Node]] = []
        var belowWidth = 1
        while true {
            let belowCount = levels.last?.count ?? leaves.count
            if belowCount < 2 {
                break
            }
            var level: [Node] = []
            level.reserveCapacity(belowCount / 2)
            for pair in 0..<(belowCount / 2) {
                let left: Node
                let right: Node
                if let below = levels.last {
                    left = below[pair * 2]
                    right = below[pair * 2 + 1]
                } else {
                    left = leaves[pair * 2].node
                    right = leaves[pair * 2 + 1].node
                }
                let name = leaves[(pair * 2 + 1) * belowWidth].name
                let items = UInt64(belowWidth)
                level.append(try fork(kind, left, items, right, items, name))
            }
            levels.append(level)
            belowWidth *= 2
        }
        self.kind = kind
        self.leaves = leaves.map(\.node)
        self.names = kind == .folder ? leaves.map(\.name) : []
        self.levels = levels
    }

    /// The name of the entry at `index`. A file's list has none.
    private func name(_ index: Int) -> [UInt8] {
        kind == .folder ? names[index] : []
    }

    /// How many items the list holds.
    public var count: UInt64 {
        UInt64(leaves.count)
    }

    /// The node on top of the list.
    public func top() throws -> Node {
        if leaves.isEmpty {
            return .emptyList
        }
        return try node(0, leaves.count)
    }

    /// The node over the `width` items that start at `offset`. Every node a
    /// walk from the top asks for either has a width that is a power of two
    /// and starts at a multiple of it, and is kept, or it lies on the list's
    /// right edge and is joined from such nodes.
    private func node(_ offset: Int, _ width: Int) throws -> Node {
        if width & (width - 1) == 0 {
            let level = width.trailingZeroBitCount
            return level == 0 ? leaves[offset] : levels[level - 1][offset >> level]
        }
        let leftWidth = Int(split(UInt64(width)))
        let left = try node(offset, leftWidth)
        let right = try node(offset + leftWidth, width - leftWidth)
        return try fork(kind, left, UInt64(leftWidth), right, UInt64(width - leftWidth), name(offset + leftWidth))
    }

    /// The nodes to send with items `start` up to, not including, `end`: one
    /// for each stretch of items that is left out, in the order a checker
    /// meets them.
    public func open(start: UInt64, end: UInt64) throws -> [Carried] {
        guard start < end, end <= count else {
            throw invalid("the items to open are outside the list")
        }
        var carried: [Carried] = []
        try collect(0, leaves.count, Int(start), Int(end), &carried)
        return carried
    }

    private func collect(_ offset: Int, _ width: Int, _ start: Int, _ end: Int, _ carried: inout [Carried]) throws {
        let after = offset + width
        if after <= start || end <= offset {
            // The node that begins the list is in no right half, and so has
            // no name that a fork hashes.
            carried.append(Carried(node: try node(offset, width), firstName: offset == 0 ? [] : name(offset)))
            return
        }
        if start <= offset && after <= end {
            return
        }
        let leftWidth = Int(split(UInt64(width)))
        try collect(offset, leftWidth, start, end, &carried)
        try collect(offset + leftWidth, width - leftWidth, start, end, &carried)
    }
}

/// Rebuilds the top of a list of `count` items from the `opened` items, which
/// start at item `start`, and the nodes `carried` for the rest.
///
/// The caller holds the result against the hash and the size that the list is
/// known by. In a folder's list every opened entry must also be where the fork
/// names send its name, so that an entry is never shown at a place where a
/// search for its name would not find it.
public func checkBranch(
    kind: ListKind,
    count: UInt64,
    start: UInt64,
    opened: [Leaf],
    carried: [Carried]
) throws -> Shown {
    try Walk.run(kind: kind, count: count, start: start, opened: opened, carried: carried, lookup: nil)
}

/// Rebuilds the top of a folder's list from the one entry at the place where
/// `name` can be, and says whether that entry has the name. Each fork sends the
/// name left when it sorts before the fork's name and right otherwise, so for
/// one folder and one name there is one place, and one answer.
public func checkLookup(
    count: UInt64,
    index: UInt64,
    entry: Leaf,
    name: [UInt8],
    carried: [Carried]
) throws -> (shown: Shown, present: Bool) {
    let shown = try Walk.run(kind: .folder, count: count, start: index, opened: [entry], carried: carried, lookup: name)
    return (shown, entry.name == name)
}

private struct Walk {
    let kind: ListKind
    let start: UInt64
    let end: UInt64
    let opened: [Leaf]
    let carried: [Carried]
    var nextCarried = 0
    var before: UInt64 = 0
    let lookup: [UInt8]?

    static func run(
        kind: ListKind,
        count: UInt64,
        start: UInt64,
        opened: [Leaf],
        carried: [Carried],
        lookup: [UInt8]?
    ) throws -> Shown {
        if count > Scionic.maxListItems {
            throw invalid("a list holds more items than the format allows")
        }
        let length = UInt64(opened.count)
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow, length > 0, end <= count else {
            throw invalid("the opened items are outside the list")
        }
        switch kind {
        case .file:
            if carried.contains(where: { !$0.firstName.isEmpty }) {
                throw invalid("a node of a file's tree carries a name")
            }
        case .folder:
            if !namesAscend(opened) {
                throw invalid("opened entries are not sorted by name, or a name is there twice")
            }
        }
        var walk = Walk(kind: kind, start: start, end: end, opened: opened, carried: carried, lookup: lookup)
        let (top, _) = try walk.node(0, count)
        if walk.nextCarried != carried.count {
            throw invalid("a branch carries more nodes than it needs")
        }
        return Shown(top: top, offset: walk.before)
    }

    private func item(_ index: UInt64) -> Leaf {
        opened[Int(index - start)]
    }

    /// The node over the `width` items that start at `offset`, and the first
    /// name under it. No more than 41 calls are ever nested, because the list
    /// holds at most 2^40 items.
    mutating func node(_ offset: UInt64, _ width: UInt64) throws -> (Node, [UInt8]) {
        let after = offset + width
        if after <= start || end <= offset {
            guard nextCarried < carried.count else {
                throw invalid("a branch carries fewer nodes than it needs")
            }
            let node = carried[nextCarried]
            nextCarried += 1
            // In a folder's tree, the node that begins the list has no name,
            // and every other carried node has one: see `Carried`.
            if kind == .folder && (offset == 0) != node.firstName.isEmpty {
                throw invalid(offset == 0
                    ? "the carried node that begins a folder's list has a name"
                    : "a carried node of a folder's tree has no name")
            }
            if after <= start {
                let (sum, overflow) = before.addingReportingOverflow(node.node.size)
                if overflow {
                    throw ScionicError.sizeOverflow(field: "list size")
                }
                before = sum
            }
            return (node.node, node.firstName)
        }
        if width == 1 {
            let leaf = item(offset)
            return (leaf.node, leaf.name)
        }
        let middle = offset + split(width)
        let (left, firstName) = try node(offset, middle - offset)
        let (right, forkName) = try node(middle, after - middle)
        if kind == .folder {
            try checkNames(offset, middle, after, forkName)
        }
        let joined = try fork(kind, left, middle - offset, right, after - middle, forkName)
        return (joined, firstName)
    }

    /// At a fork of a folder's tree: every opened entry on its left sorts
    /// before the fork's name, and every opened entry on its right sorts after
    /// it, except the right half's own first entry, which has that name. A
    /// name that is looked up takes the same turn as the entry it is shown.
    private func checkNames(_ offset: UInt64, _ middle: UInt64, _ after: UInt64, _ forkName: [UInt8]) throws {
        let leftEnd = min(end, middle)
        if max(start, offset) < leftEnd && !bytesLess(item(leftEnd - 1).name, forkName) {
            throw invalid("an entry is left of a fork whose name it does not sort before")
        }
        let rightStart = max(start, middle)
        if rightStart > middle && rightStart < min(end, after) && !bytesLess(forkName, item(rightStart).name) {
            throw invalid("an entry is right of a fork whose name it does not sort after")
        }
        if let name = lookup {
            let nameGoesLeft = bytesLess(name, forkName)
            let entryIsLeft = start < middle
            if nameGoesLeft != entryIsLeft {
                throw invalid("the opened entry is not where the name would be")
            }
        }
    }
}
