import Foundation
@testable import proofsizes
import XCTest

// The example is run, and the README's two tables are held to it: a branch
// size that the README gives is the size that is measured here.

/// One row of a table: how many entries or chunks, and how many bytes the
/// whole list and a branch take.
private struct Measured {
    let count: Int
    let list: Int
    let branch: Int
}

private let folderRows = [
    Measured(count: 10, list: 610, branch: 300),
    Measured(count: 1_000, list: 61_000, branch: 648),
    Measured(count: 10_000, list: 610_000, branch: 880),
    Measured(count: 1_000_000, list: 61_000_000, branch: 1228),
]

private let fileRows = [
    Measured(count: 10, list: 360, branch: 219),
    Measured(count: 1_000, list: 36_000, branch: 459),
    Measured(count: 10_000, list: 360_000, branch: 619),
    Measured(count: 500_000, list: 18_000_000, branch: 819),
]

/// A number as the README writes it: 1,228.
private func withCommas(_ number: Int) -> String {
    var digits = String(number)
    var at = digits.count - 3
    while at > 0 {
        digits.insert(",", at: digits.index(digits.startIndex, offsetBy: at))
        at -= 3
    }
    return digits
}

final class ProofSizesTests: XCTestCase {
    // Each row that is printed is measured: the whole list as the store keeps
    // it, and a branch as a responder sends it. The folder of a million
    // entries takes a while to build, so the tables are measured once.
    func testABranchIsAsSmallAsTheTablesSay() throws {
        var printed = ""
        try sizes(to: &printed)
        for row in folderRows + fileRows {
            let want = column(String(row.count), 10) + "  " + column(String(row.list), 12) + "  "
                + column(String(row.branch), 8) + "  "
            XCTAssertTrue(printed.contains(want), "the example did not print \(want):\n\(printed)")
        }
        XCTAssertTrue(
            printed.contains("49674x") && printed.contains("21978x"),
            "the example did not print how much smaller the longest branches are:\n\(printed)"
        )
    }

    func testTheReadmeGivesTheSizesThatAreMeasured() throws {
        let readme = String(decoding: try packageFile("README.md"), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(folderCounts, folderRows.map(\.count), "the example measures other sizes than the tables have")
        XCTAssertEqual(fileCounts, fileRows.map(\.count), "the example measures other sizes than the tables have")
        // A row of the README starts with the count, and has the branch's size
        // in its own column.
        for row in folderRows + fileRows {
            let start = "| " + withCommas(row.count) + " |"
            let branch = "| " + withCommas(row.branch) + " bytes |"
            let found = readme.split(separator: "\n").contains { $0.hasPrefix(start) && $0.contains(branch) }
            XCTAssertTrue(found, "the README has no row for \(withCommas(row.count)) with a branch of \(withCommas(row.branch)) bytes")
        }
    }
}
