import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Chunk reassembly ordering, including the legacy path-prefixed names written
/// by older builders.
///
/// The regression these guard against: the three reassembly comparators used
/// `NSString.lastPathComponent`, which recognizes only the HOST's separator. On a
/// POSIX reader a Windows-authored `file\10` stayed non-numeric, the comparator
/// fell back to lexical order, and chunk 10 was reassembled before chunk 2. Link
/// order is not covered by any hash, so the corrupted file still verifies.
final class ChunkOrderTests: XCTestCase {

    // MARK: - Index extraction

    func testBareIndexParses() {
        XCTAssertEqual(chunkIndexFromItemName("0"), 0)
        XCTAssertEqual(chunkIndexFromItemName("2"), 2)
        XCTAssertEqual(chunkIndexFromItemName("10"), 10)
    }

    func testUnixLegacyPrefixIsStripped() {
        XCTAssertEqual(chunkIndexFromItemName("file/0"), 0)
        XCTAssertEqual(chunkIndexFromItemName("a/b/c/10"), 10)
    }

    /// The actual regression. Must hold on EVERY host, not just Windows.
    func testWindowsLegacyPrefixIsStrippedOnAnyHost() {
        XCTAssertEqual(chunkIndexFromItemName("file\\0"), 0)
        XCTAssertEqual(chunkIndexFromItemName("file\\2"), 2)
        XCTAssertEqual(chunkIndexFromItemName("file\\10"), 10)
        XCTAssertEqual(chunkIndexFromItemName("a\\b\\c\\10"), 10)
    }

    func testNonNumericNameHasNoIndex() {
        XCTAssertNil(chunkIndexFromItemName("readme.md"))
        XCTAssertNil(chunkIndexFromItemName("file/name.txt"))
        XCTAssertNil(chunkIndexFromItemName(""))
    }

    // MARK: - Ordering

    /// 2 before 10 is the case lexical order gets wrong.
    func testNumericOrderBeatsLexicalOrder() {
        XCTAssertTrue(compareChunkItemNames("2", "10"))
        XCTAssertFalse(compareChunkItemNames("10", "2"))
    }

    func testUnixLegacyNamesOrderNumerically() {
        XCTAssertTrue(compareChunkItemNames("file/2", "file/10"))
        XCTAssertFalse(compareChunkItemNames("file/10", "file/2"))
    }

    /// Pre-fix this returned false on POSIX, because "file\\10" < "file\\2"
    /// lexically. This assertion is the mutation guard.
    func testWindowsLegacyNamesOrderNumericallyOnAnyHost() {
        XCTAssertTrue(compareChunkItemNames("file\\2", "file\\10"))
        XCTAssertFalse(compareChunkItemNames("file\\10", "file\\2"))
    }

    func testNonNumericNamesFallBackToFullNameLexicalOrder() {
        // Go's compareChunkItemNames compares the WHOLE original name on
        // fallback, not the extracted basename. Mirror that exactly.
        XCTAssertTrue(compareChunkItemNames("a/zzz", "b/aaa"))
        XCTAssertFalse(compareChunkItemNames("b/aaa", "a/zzz"))
    }

    // MARK: - Sorting a permuted chunk list

    func testPermutedChunkNamesSortIntoIndexOrder() {
        let expected = (0 ..< 12).map(String.init)
        for prefix in ["", "file/", "file\\", "deep/dir/", "deep\\dir\\"] {
            let names = (0 ..< 12).map { prefix + String($0) }
            // Shuffle deterministically by reversing, and also test a rotation,
            // so the assertion cannot pass just because input was already sorted.
            for permuted in [names.reversed().map { $0 }, Array(names[5...] + names[..<5])] {
                let sorted = permuted.sorted(by: compareChunkItemNames)
                // Deliberately NOT force-unwrapped. If a regression makes a
                // separator unrecognizable, every index here is nil -- and a
                // force-unwrap aborts the whole test process, taking the other
                // prefixes and every other test in this file down with it and
                // reporting a crash instead of the ordering failure. Verified:
                // with the force-unwrap this mutation produced one fatal error
                // and no diagnosis; without it, ten assertions naming file\10
                // sorted ahead of file\2.
                let indices = sorted.map { chunkIndexFromItemName($0).map(String.init) ?? "nil(\($0))" }
                XCTAssertEqual(
                    indices, expected,
                    "prefix '\(prefix)' did not sort into chunk-index order"
                )
            }
        }
    }
}
