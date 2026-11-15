// The format, written a second time and as plainly as it can be.
//
// Nothing here is shared with the library but SHA-256. Each function is the rule
// as spec/FORMAT.md states it, with no shortcut: a tree is hashed by halving, a
// branch is found by walking. It does two jobs. It says what the library's
// hashes have to be, from another hand. And it forges: it hashes lists that the
// library refuses to make, such as a folder that is out of order on purpose, the
// way an author with code of his own could.

@testable import ScionicMerkleTree

enum Oracle {
    typealias H = [UInt8]

    static func sha(_ parts: [UInt8]...) -> H {
        Hash.of(Array(parts.joined())).bytes
    }

    /// One item of a file's list.
    struct Item {
        var hash: H
        var length: UInt32

        static func of(_ bytes: [UInt8]) -> Item {
            Item(hash: sha(bytes), length: UInt32(bytes.count))
        }

        var bytes: [UInt8] {
            hash + u32be(length)
        }
    }

    /// One entry of a folder's list.
    struct Entry {
        /// 1 for a file, 2 for a folder.
        var kind: UInt8
        var size: UInt64
        var hash: H
        var name: [UInt8]
        /// Named values, in the order they are to be written.
        var extra: [([UInt8], [UInt8])] = []

        static func file(_ name: String, _ hash: H, _ size: UInt64) -> Entry {
            Entry(kind: 1, size: size, hash: hash, name: Array(name.utf8))
        }

        static func folder(_ name: String, _ hash: H, _ size: UInt64) -> Entry {
            Entry(kind: 2, size: size, hash: hash, name: Array(name.utf8))
        }

        var bytes: [UInt8] {
            [kind] + u64be(size) + hash + u16be(UInt16(name.count)) + name + extraBytes(extra)
        }
    }

    static func extraBytes(_ extra: [([UInt8], [UInt8])]) -> [UInt8] {
        var out = u16be(UInt16(extra.count))
        for (name, value) in extra {
            out += u16be(UInt16(name.count)) + name + u16be(UInt16(value.count)) + value
        }
        return out
    }

    /// A node of a list's tree: its hash, and the bytes of content under it.
    typealias Node = (hash: H, size: UInt64)

    /// A list as its tree sees it: a leaf for each item, and for a folder each
    /// entry's name.
    struct Leaves {
        /// 0x01 for a file's tree, 0x03 for a folder's.
        var forkMark: UInt8
        var nodes: [Node]
        var names: [[UInt8]]

        func firstName(_ offset: Int) -> [UInt8] {
            forkMark == 0x03 ? names[offset] : []
        }

        /// The node over the `width` items from `offset`, by the rule.
        func node(_ offset: Int, _ width: Int) -> Node {
            if width == 1 {
                return nodes[offset]
            }
            let half = leftHalf(width)
            let left = node(offset, half)
            let right = node(offset + half, width - half)
            return fork(forkMark, left, UInt64(half), right, UInt64(width - half), firstName(offset + half))
        }

        /// The node on top of the list. An empty list has 32 zero bytes.
        func top() -> Node {
            nodes.isEmpty ? ([UInt8](repeating: 0, count: 32), 0) : node(0, nodes.count)
        }

        /// The nodes to carry when items `start` up to `end` are shown: one for
        /// each branch that is left out, in the order a checker meets them, each
        /// with the first name under it. The node that begins the list has no
        /// name: it is in no right half, so no fork hashes one for it.
        func carried(_ start: Int, _ end: Int) -> [(Node, [UInt8])] {
            var out: [(Node, [UInt8])] = []
            collect(0, nodes.count, start, end, &out)
            return out
        }

        private func collect(_ offset: Int, _ width: Int, _ start: Int, _ end: Int, _ out: inout [(Node, [UInt8])]) {
            if offset + width <= start || end <= offset {
                out.append((node(offset, width), offset == 0 ? [] : firstName(offset)))
            } else if width > 1 {
                let half = leftHalf(width)
                collect(offset, half, start, end, &out)
                collect(offset + half, width - half, start, end, &out)
            }
        }
    }

    static func fileLeaves(_ items: [Item]) -> Leaves {
        Leaves(forkMark: 0x01, nodes: items.map { (sha([0x00], $0.bytes), UInt64($0.length)) }, names: [])
    }

    static func folderLeaves(_ entries: [Entry]) -> Leaves {
        Leaves(forkMark: 0x03, nodes: entries.map { (sha([0x02], $0.bytes), $0.size) }, names: entries.map(\.name))
    }

    /// The largest power of two that is less than `width`.
    static func leftHalf(_ width: Int) -> Int {
        var half = 1
        while half * 2 < width {
            half *= 2
        }
        return half
    }

    static func fork(_ mark: UInt8, _ left: Node, _ leftItems: UInt64, _ right: Node, _ rightItems: UInt64, _ name: [UInt8]) -> Node {
        let hash = sha(
            [mark],
            left.hash, u64be(left.size), u64be(leftItems),
            right.hash, u64be(right.size), u64be(rightItems),
            mark == 0x03 ? name : []
        )
        return (hash, left.size + right.size)
    }

    /// A file's hash and size, from its list.
    static func fileHash(_ items: [Item]) -> Node {
        let top = fileLeaves(items).top()
        return (sha([0x10], u64be(UInt64(items.count)), u64be(top.size), top.hash), top.size)
    }

    /// A folder's hash and size, from its list as it is given: nothing is
    /// sorted, and nothing is checked.
    static func folderHash(_ entries: [Entry]) -> Node {
        let top = folderLeaves(entries).top()
        return (sha([0x11], u64be(UInt64(entries.count)), u64be(top.size), top.hash), top.size)
    }

    static func fileListBytes(_ items: [Item]) -> [UInt8] {
        items.flatMap(\.bytes)
    }

    static func folderListBytes(_ entries: [Entry]) -> [UInt8] {
        entries.flatMap(\.bytes)
    }

    /// A record's bytes. Its hash is the root.
    static func recordBytes(
        _ kind: UInt8,
        _ size: UInt64,
        _ hash: H,
        _ totals: (UInt64, UInt64, UInt64),
        _ extra: [([UInt8], [UInt8])]
    ) -> [UInt8] {
        // Written a part at a time: Swift 6.0 takes too long over it in one.
        var out: [UInt8] = [0x20, kind]
        out += u64be(size)
        out += hash
        out += u64be(totals.0)
        out += u64be(totals.1)
        out += u64be(totals.2)
        out += extraBytes(extra)
        return out
    }

    /// The extra data of a record that says only how the tree was chunked.
    static func chunkingTag(_ tag: String) -> [([UInt8], [UInt8])] {
        [(Array("chunking".utf8), Array(tag.utf8))]
    }

    /// The frame that shows items `start` up to `end` of a file's list.
    static func fileBranchFrame(_ items: [Item], _ start: Int, _ end: Int) -> [UInt8] {
        fileBranchFrameAs(UInt64(items.count), UInt64(start), Array(items[start..<end]), fileLeaves(items).carried(start, end))
    }

    /// A file-branch frame from its parts, whatever they say.
    static func fileBranchFrameAs(_ count: UInt64, _ start: UInt64, _ shown: [Item], _ carried: [(Node, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = [0x23] + u64be(count) + u64be(start) + u32be(UInt32(shown.count)) + fileListBytes(shown)
        out += u16be(UInt16(carried.count))
        for (node, _) in carried {
            out += node.hash + u64be(node.size)
        }
        return out
    }

    /// The frame that shows entries `start` up to `end` of a folder's list.
    static func folderBranchFrame(_ entries: [Entry], _ start: Int, _ end: Int) -> [UInt8] {
        folderBranchFrameAs(
            UInt64(entries.count),
            UInt64(start),
            Array(entries[start..<end]),
            folderLeaves(entries).carried(start, end)
        )
    }

    /// A folder-branch frame from its parts, whatever they say.
    static func folderBranchFrameAs(_ count: UInt64, _ start: UInt64, _ shown: [Entry], _ carried: [(Node, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = [0x24] + u64be(count) + u64be(start) + u32be(UInt32(shown.count)) + folderListBytes(shown)
        out += u16be(UInt16(carried.count))
        for (node, name) in carried {
            out += node.hash + u64be(node.size) + u16be(UInt16(name.count)) + name
        }
        return out
    }

    /// A frame: its first byte, and its body.
    static func frame(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + body
    }
}
