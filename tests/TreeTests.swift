import XCTest
@testable import ScionicMerkleTree

final class TreeTests: XCTestCase {
    private func leafNode(_ seed: Int) -> Node {
        Node(hash: Hash.of(u64be(UInt64(seed))), size: UInt64(seed) % 7 + 1)
    }

    private func fileList(_ count: Int) -> [Leaf] {
        (0..<count).map { Leaf(node: leafNode($0)) }
    }

    private func folderList(_ names: [String]) -> [Leaf] {
        names.enumerated().map { Leaf(node: leafNode($0.offset), name: bytes($0.element)) }
    }

    private func sortedFolder(_ count: Int) -> [Leaf] {
        (0..<count).map { Leaf(node: leafNode($0), name: bytes("name-" + padded($0, 4))) }
    }

    /// The rule as it is written, with no stack and no kept levels.
    private func byTheRule(_ kind: ListKind, _ leaves: [Leaf], _ offset: Int, _ width: Int) -> Node {
        if width == 1 {
            return leaves[offset].node
        }
        var leftWidth = 1
        while leftWidth * 2 < width {
            leftWidth *= 2
        }
        let left = byTheRule(kind, leaves, offset, leftWidth)
        let right = byTheRule(kind, leaves, offset + leftWidth, width - leftWidth)
        return try! fork(kind, left, UInt64(leftWidth), right, UInt64(width - leftWidth), leaves[offset + leftWidth].name)
    }

    func testAListIsHalvedAtTheLargestPowerOfTwoBelowItsLength() {
        for (width, left) in [(2, 1), (3, 2), (4, 2), (5, 4), (6, 4), (8, 4), (9, 8)] as [(UInt64, UInt64)] {
            XCTAssertEqual(split(width), left, "a list of \(width)")
        }
        XCTAssertEqual(split(Scionic.maxListItems), Scionic.maxListItems / 2)
        XCTAssertEqual(split(Scionic.maxListItems + 1), Scionic.maxListItems)
    }

    func testAForkHashesExactlyTheBytesTheFormatNames() throws {
        let left = leafNode(1)
        let right = leafNode(2)
        var all: [UInt8] = [0x01]
        all += left.hash.bytes + u64be(left.size) + u64be(4)
        all += right.hash.bytes + u64be(right.size) + u64be(3)
        XCTAssertEqual(all.count, 97)
        let file = try fork(.file, left, 4, right, 3, bytes("ignored"))
        XCTAssertEqual(file.hash, Hash.of(all))
        XCTAssertEqual(file.size, left.size + right.size)
        // The same two halves over another number of items are another fork.
        XCTAssertNotEqual(try fork(.file, left, 4, right, 2, bytes("ignored")).hash, file.hash)
        all[0] = 0x03
        all += bytes("right-half")
        let folder = try fork(.folder, left, 4, right, 3, bytes("right-half"))
        XCTAssertEqual(folder.hash, Hash.of(all))
        XCTAssertNotEqual(folder.hash, file.hash)
    }

    func testTheTopOfAListFollowsTheRuleAtEveryLength() throws {
        XCTAssertEqual(try topOf(.file, []), .emptyList)
        XCTAssertEqual(try topOf(.folder, []), .emptyList)
        for count in 1...70 {
            for (kind, leaves) in [(ListKind.file, fileList(count)), (.folder, sortedFolder(count))] {
                let expected = byTheRule(kind, leaves, 0, count)
                XCTAssertEqual(try topOf(kind, leaves), expected, "\(kind) of \(count)")
                XCTAssertEqual(try ListTree(kind: kind, leaves: leaves).top(), expected, "kept \(kind) of \(count)")
            }
        }
    }

    func testAListOfOneIsItsLeafAndALongerListIsNeverOneOfItsLeaves() throws {
        let leaves = fileList(3)
        XCTAssertEqual(try topOf(.file, Array(leaves[..<1])), leaves[0].node)
        let top = try topOf(.file, leaves)
        XCTAssertTrue(leaves.allSatisfy { $0.node.hash != top.hash })
        XCTAssertEqual(top.size, leaves.reduce(0) { $0 + $1.node.size })
    }

    func testTheSameItemsInAnotherOrderOrNumberGiveAnotherTop() throws {
        var leaves = fileList(6)
        let top = try topOf(.file, leaves)
        // A last item that is listed twice is a longer list, not the same one.
        XCTAssertNotEqual(try topOf(.file, leaves + [leaves[5]]).hash, top.hash)
        XCTAssertNotEqual(try topOf(.file, Array(leaves[..<5])).hash, top.hash)
        leaves.swapAt(1, 2)
        XCTAssertNotEqual(try topOf(.file, leaves).hash, top.hash)
    }

    func testAFolderListOutOfOrderOrWithANameTwiceHasNoHash() {
        for names in [["b", "a"], ["a", "a"], ["a", "c", "b"]] {
            let leaves = folderList(names)
            XCTAssertThrowsError(try topOf(.folder, leaves), "\(names)")
            XCTAssertThrowsError(try ListTree(kind: .folder, leaves: leaves), "\(names)")
        }
    }

    func testNamesAreOrderedByTheirBytesAndNotAsSwiftComparesText() throws {
        // "\u{E9}" and "e\u{301}" are one string to Swift and two names to the
        // format, in the order of their bytes: 0x65 comes before 0xC3.
        let decomposed = Leaf(node: leafNode(1), name: bytes("e\u{301}"))
        let composed = Leaf(node: leafNode(2), name: bytes("\u{E9}"))
        XCTAssertNoThrow(try topOf(.folder, [decomposed, composed]))
        XCTAssertThrowsError(try topOf(.folder, [composed, decomposed]))
    }

    func testEveryBranchOfEveryListOpensAndRebuildsToTheTop() throws {
        for count in 1...33 {
            for (kind, leaves) in [(ListKind.file, fileList(count)), (.folder, sortedFolder(count))] {
                let tree = try ListTree(kind: kind, leaves: leaves)
                let top = try tree.top()
                for start in 0..<count {
                    for end in (start + 1)...count {
                        let what = "\(kind) of \(count), \(start)..<\(end)"
                        let carried = try tree.open(start: UInt64(start), end: UInt64(end))
                        let shown = try checkBranch(
                            kind: kind, count: UInt64(count), start: UInt64(start),
                            opened: Array(leaves[start..<end]), carried: carried
                        )
                        XCTAssertEqual(shown.top, top, what)
                        XCTAssertEqual(shown.offset, leaves[..<start].reduce(0) { $0 + $1.node.size }, what)
                        // A branch carries a node for each stretch of the list it
                        // leaves out, and never more than two for a level.
                        XCTAssertLessThanOrEqual(carried.count, 2 * 6, what)
                        if start == 0 && end == count {
                            XCTAssertTrue(carried.isEmpty, what)
                        }
                    }
                }
            }
        }
    }

    func testABranchThatIsChangedDoesNotRebuildToTheTop() throws {
        let leaves = fileList(11)
        let tree = try ListTree(kind: .file, leaves: leaves)
        let top = try tree.top()
        let carried = try tree.open(start: 4, end: 6)
        func rebuilt(_ start: UInt64, _ opened: [Leaf], _ carried: [Carried]) -> Node? {
            try? checkBranch(kind: .file, count: 11, start: start, opened: opened, carried: carried).top
        }
        XCTAssertEqual(rebuilt(4, Array(leaves[4..<6]), carried), top)
        // Another item in an opened place, and the same items one place on.
        XCTAssertNotEqual(rebuilt(4, [leaves[4], leaves[7]], carried), top)
        XCTAssertNotEqual(rebuilt(5, Array(leaves[4..<6]), carried), top)
        // The same item with another size.
        var resized = leaves[4]
        resized.node.size += 1
        XCTAssertNotEqual(rebuilt(4, [resized, leaves[5]], carried), top)
        // A carried node with another size, two carried nodes changed about,
        // one too few and one too many.
        var wrongSize = carried
        wrongSize[0].node.size += 1
        XCTAssertNotEqual(rebuilt(4, Array(leaves[4..<6]), wrongSize), top)
        var swapped = carried
        swapped.swapAt(0, 1)
        XCTAssertNotEqual(rebuilt(4, Array(leaves[4..<6]), swapped), top)
        XCTAssertNil(rebuilt(4, Array(leaves[4..<6]), Array(carried.dropFirst())))
        XCTAssertNil(rebuilt(4, Array(leaves[4..<6]), carried + [carried[0]]))
        // A list that is said to be longer or shorter.
        for count: UInt64 in [10, 12] {
            let result = try? checkBranch(kind: .file, count: count, start: 4, opened: Array(leaves[4..<6]), carried: carried)
            XCTAssertNotEqual(result?.top, top, "as \(count) items")
        }
        // Items outside the list, and none at all.
        XCTAssertNil(rebuilt(10, Array(leaves[4..<6]), carried))
        XCTAssertNil(rebuilt(4, [], carried))
        XCTAssertNil(rebuilt(UInt64.max, Array(leaves[4..<6]), carried))
    }

    func testNoPlaceExistsBeyondTheCount() throws {
        // Trees that fill a level by repeating their last item let that item be
        // shown again at the place after it. Here the place is not there.
        for count in [1, 3, 5, 7] {
            let leaves = fileList(count)
            let tree = try ListTree(kind: .file, leaves: leaves)
            let carried = try tree.open(start: UInt64(count - 1), end: UInt64(count))
            XCTAssertThrowsError(try checkBranch(
                kind: .file, count: UInt64(count), start: UInt64(count),
                opened: [leaves[count - 1]], carried: carried
            ))
            XCTAssertThrowsError(try tree.open(start: UInt64(count), end: UInt64(count + 1)))
        }
    }

    func testSizesThatDoNotFitAreAnError() {
        var leaves = fileList(2)
        leaves[0].node.size = UInt64.max
        XCTAssertThrowsError(try topOf(.file, leaves))
        XCTAssertThrowsError(try ListTree(kind: .file, leaves: leaves))
    }

    func testANameInASortedFolderIsFoundAtItsOnePlaceOrShownMissing() throws {
        for count in 1...20 {
            let leaves = sortedFolder(count)
            let tree = try ListTree(kind: .folder, leaves: leaves)
            let top = try tree.top()
            func verdict(_ name: [UInt8], _ index: Int) -> Bool? {
                let carried = try! tree.open(start: UInt64(index), end: UInt64(index + 1))
                guard let (shown, present) = try? checkLookup(
                    count: UInt64(count), index: UInt64(index), entry: leaves[index], name: name, carried: carried
                ), shown.top == top else {
                    return nil
                }
                return present
            }
            for (place, leaf) in leaves.enumerated() {
                // The name itself: there, at its own place and nowhere else.
                for index in 0..<count {
                    XCTAssertEqual(verdict(leaf.name, index), index == place ? true : nil, "\(count): \(place) at \(index)")
                }
                // A name just after it: missing, shown by the entry before it,
                // and by no other entry.
                for index in 0..<count {
                    XCTAssertEqual(verdict(leaf.name + bytes("!"), index), index == place ? false : nil, "\(count): after \(place) at \(index)")
                }
            }
            // A name before every entry: missing, shown by the first entry.
            for index in 0..<count {
                XCTAssertEqual(verdict(bytes("a"), index), index == 0 ? false : nil, "\(count): before all at \(index)")
            }
        }
    }

    func testAFolderBuiltOutOfOrderCannotShowOneNameAtTwoPlaces() throws {
        // An author is free to hash any list. Whatever it hashed, a name has one
        // place, and an entry anywhere else cannot be shown at all.
        var numbers = Numbers(0x5C10_71C5_EED5_EED5)
        let alphabet = ["a", "b", "c", "d", "e", "f"]
        for _ in 0..<400 {
            let count = 2 + numbers.next(16)
            let names = (0..<count).map { _ in alphabet[numbers.next(alphabet.count)] }
            let leaves = folderList(names)
            let tree = try ListTree(unchecked: .folder, leaves: leaves)
            let top = try tree.top()
            for name in alphabet {
                var answers: [(Int, Bool)] = []
                for (index, entry) in leaves.enumerated() {
                    let carried = try tree.open(start: UInt64(index), end: UInt64(index + 1))
                    if let (shown, present) = try? checkLookup(
                        count: UInt64(count), index: UInt64(index), entry: entry, name: bytes(name), carried: carried
                    ), shown.top == top {
                        answers.append((index, present))
                    }
                    // An entry with this name that is shown as a plain branch
                    // passes only at the place a search would reach.
                    if entry.name == bytes(name) {
                        let plain = try? checkBranch(
                            kind: .folder, count: UInt64(count), start: UInt64(index), opened: [entry], carried: carried
                        )
                        let foundHere = answers.last.map { $0 == (index, true) } ?? false
                        XCTAssertEqual(plain?.top == top, foundHere, "\(names): \(name) at \(index)")
                    }
                }
                XCTAssertLessThanOrEqual(answers.count, 1, "\(names): \(name) answered at \(answers)")
            }
        }
    }

    func testBranchesOfAFolderBuiltOutOfOrderOpenOnlyWhereASearchAgrees() throws {
        // "c" sits left of a fork named "b": it cannot be shown, alone or in a
        // branch, and a search for it is sent to "b", which says it is missing.
        let leaves = folderList(["a", "c", "b", "d"])
        let tree = try ListTree(unchecked: .folder, leaves: leaves)
        let top = try tree.top()
        func opens(_ start: Int, _ end: Int) -> Bool {
            let carried = try! tree.open(start: UInt64(start), end: UInt64(end))
            let shown = try? checkBranch(kind: .folder, count: 4, start: UInt64(start), opened: Array(leaves[start..<end]), carried: carried)
            return shown?.top == top
        }
        XCTAssertTrue(opens(0, 1), "a")
        XCTAssertFalse(opens(1, 2), "c, alone")
        XCTAssertFalse(opens(0, 2), "a and c")
        XCTAssertFalse(opens(1, 3), "c and b")
        XCTAssertTrue(opens(2, 3), "b")
        XCTAssertTrue(opens(2, 4), "b and d")
        XCTAssertFalse(opens(0, 4), "the whole list")
        let carried = try tree.open(start: 2, end: 3)
        let (shown, present) = try checkLookup(count: 4, index: 2, entry: leaves[2], name: bytes("c"), carried: carried)
        XCTAssertEqual(shown.top, top)
        XCTAssertFalse(present)
    }

    func testACarriedNameIsHeldToTheForkItEnters() throws {
        // The first name under a carried right half is part of the fork above
        // it. Another name there gives another top.
        let leaves = sortedFolder(8)
        let tree = try ListTree(kind: .folder, leaves: leaves)
        let top = try tree.top()
        var carried = try tree.open(start: 1, end: 2)
        XCTAssertEqual(try checkBranch(kind: .folder, count: 8, start: 1, opened: [leaves[1]], carried: carried).top, top)
        carried[carried.count - 1].firstName = bytes("name-9999")
        let forged = try? checkBranch(kind: .folder, count: 8, start: 1, opened: [leaves[1]], carried: carried)
        XCTAssertNotEqual(forged?.top, top)
    }

    func testAFilesTreeCarriesNoNames() throws {
        let leaves = fileList(4)
        let tree = try ListTree(kind: .file, leaves: leaves)
        var carried = try tree.open(start: 0, end: 1)
        carried[0].firstName = bytes("x")
        XCTAssertThrowsError(try checkBranch(kind: .file, count: 4, start: 0, opened: [leaves[0]], carried: carried))
    }

    func testTheCarriedNodeThatBeginsAFoldersListHasNoName() throws {
        // A fork hashes the first name of its right half. The node that begins
        // the list is in no right half, so nothing would cover a name for it: it
        // has none, and one that comes with a name is refused. Every other
        // carried node has the name its fork hashes, and no other.
        for count in 2...20 {
            let leaves = sortedFolder(count)
            let tree = try ListTree(kind: .folder, leaves: leaves)
            let top = try tree.top()
            for start in 0..<count {
                for end in (start + 1)...count {
                    let carried = try tree.open(start: UInt64(start), end: UInt64(end))
                    func rebuilds(_ carried: [Carried]) -> Bool {
                        let shown = try? checkBranch(
                            kind: .folder, count: UInt64(count), start: UInt64(start),
                            opened: Array(leaves[start..<end]), carried: carried
                        )
                        return shown?.top == top
                    }
                    XCTAssertTrue(rebuilds(carried), "\(count): \(start)..<\(end)")
                    for index in carried.indices {
                        let what = "\(count): \(start)..<\(end), carried node \(index)"
                        let beginsTheList = index == 0 && start > 0
                        XCTAssertEqual(carried[index].firstName.isEmpty, beginsTheList, what)
                        var renamed = carried
                        renamed[index].firstName = bytes("name-9999")
                        XCTAssertFalse(rebuilds(renamed), what + ", under another name")
                        var nameless = carried
                        nameless[index].firstName = []
                        XCTAssertEqual(rebuilds(nameless), beginsTheList, what + ", nameless")
                    }
                }
            }
        }
    }
}
