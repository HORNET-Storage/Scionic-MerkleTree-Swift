import Foundation
import ScionicMerkleTree
import XCTest

// The README is held to the package, so that it cannot fall behind it: the
// version it names, the Swift code it shows, the programs it tells a reader to
// run, the pictures it shows, and the files it points to. Its tables of branch
// sizes are held to the program that measures them, in ProofSizesTests.

/// A file of the package as text, with the line endings that the checkout gave
/// made plain.
private func packageText(_ path: String) throws -> String {
    String(decoding: try packageFile(path), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
}

/// The place of a file or a folder of the package, by its path with `/`.
private func packageURL(_ path: String) -> URL {
    path.split(separator: "/").reduce(packageFolder) { $0.appendingPathComponent(String($1)) }
}

/// Whether a file or a folder of the package is there.
private func packageHas(_ path: String) -> Bool {
    (try? packageURL(path).checkResourceIsReachable()) ?? false
}

/// The oldest Swift the package supports: the one its manifest names.
private func oldestSwift() throws -> String {
    let prefix = "// swift-tools-version:"
    guard let first = try packageText("Package.swift").split(separator: "\n").first, first.hasPrefix(prefix) else {
        throw TestFailure("Package.swift names no version of Swift")
    }
    return first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
}

/// The anchor that a heading gets: lower case, with a hyphen for each space,
/// and nothing but letters, digits and hyphens.
private func anchorOf<Title: StringProtocol>(_ title: Title) -> String {
    var anchor = ""
    for letter in title.lowercased() {
        if letter == " " {
            anchor.append("-")
        } else if letter == "-" || ("a"..."z").contains(letter) || ("0"..."9").contains(letter) {
            anchor.append(letter)
        }
    }
    return anchor
}

/// The lines of a text without the space around them, and without the empty
/// ones.
private func trimmed(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Whether every one of `lines` stands in `source`, in the same order.
private func inOrder(_ lines: [String], _ source: [String]) -> Bool {
    var at = 0
    for line in source where at < lines.count && line == lines[at] {
        at += 1
    }
    return at == lines.count
}

/// A text without its blocks of code, where `](` is code and not a link, and
/// `#` does not begin a heading.
private func prose(_ text: String) -> String {
    text.components(separatedBy: "```").enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: "\n")
}

final class ReadmeTests: XCTestCase {
    func testTheReadmeNamesThisVersion() throws {
        // The three libraries carry one version number.
        XCTAssertEqual(Scionic.version, "2.5.6")
        let text = try packageText("README.md")
        for want in [
            "version-\(Scionic.version)-",
            "version \(Scionic.version)",
            "What's New in \(Scionic.version)",
            "from: \"\(Scionic.version)\"",
        ] {
            XCTAssertTrue(text.contains(want), "the README does not say \(want)")
        }
        // The oldest Swift the package supports is the one its manifest names,
        // and the one that CI runs the tests on once more.
        let oldest = try oldestSwift()
        for want in ["swift-\(oldest)%2B", "| Swift | \(oldest) or newer |", "on Swift \(oldest),"] {
            XCTAssertTrue(text.contains(want), "the README does not say \(want)")
        }
        XCTAssertTrue(
            try packageText(".github/workflows/ci.yml").contains("swift-\(oldest)."),
            "CI does not run the tests on Swift \(oldest)"
        )
    }

    func testEveryProgramTheReadmeRunsIsThere() throws {
        let text = try packageText("README.md")
        let manifest = try packageText("Package.swift")
        // Each `swift run -c release <name>` names a program.
        var named = 0
        for after in text.components(separatedBy: "swift run -c release ").dropFirst() {
            let name = String(after.prefix { !$0.isWhitespace })
            XCTAssertTrue(packageHas("examples/\(name)/\(name).swift"), "the README runs a program that is not there: \(name)")
            XCTAssertTrue(manifest.contains(".executableTarget(name: \"\(name)\""), "the package does not build \(name)")
            named += 1
        }
        XCTAssertGreaterThanOrEqual(named, 3, "the README does not run the package's programs")
        // And every program the package has is one the README tells of.
        let programs = try FileManager.default.contentsOfDirectory(at: packageURL("examples"), includingPropertiesForKeys: nil)
        XCTAssertEqual(programs.count, 3)
        for program in programs {
            let name = program.lastPathComponent
            XCTAssertTrue(text.contains("swift run -c release \(name)"), "the README does not tell of examples/\(name)")
        }
    }

    // The README's three pictures are its author's own, and stay through every
    // rewrite of the text around them: the one under the opening, and the two
    // that have a heading each. Which picture stands there is the author's to
    // change, so this holds the places and not the pictures.
    func testTheReadmeKeepsItsPictures() throws {
        let text = try packageText("README.md")
        guard let contents = text.range(of: "\n## Contents\n") else {
            return XCTFail("the README has no contents")
        }
        XCTAssertTrue(text[..<contents.lowerBound].contains("\n!["), "the README has no picture under its opening")
        for heading in ["### Scionic Merkle Tree", "### Scionic Merkle Branch"] {
            guard let at = text.range(of: "\n\(heading)\n") else {
                XCTFail("the README has no heading \(heading)")
                continue
            }
            XCTAssertTrue(text[at.upperBound...].drop { $0 == "\n" }.hasPrefix("!["), "the README has no picture under \(heading)")
        }
    }

    // A picture that the README takes from the repository is a picture: a PNG
    // that is whole, and wide enough to be read at the width of a page.
    func testThePicturesTheReadmeShowsOpen() throws {
        var pictures = 0
        for after in try packageText("README.md").components(separatedBy: "\n![").dropFirst() {
            guard let open = after.range(of: "]("), let close = after[open.upperBound...].firstIndex(of: ")") else {
                continue
            }
            let target = String(after[open.upperBound..<close])
            if target.hasPrefix("http") {
                continue
            }
            let bytes = try packageFile(target)
            // The PNG signature, then the header's length and name.
            let start: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]
            XCTAssertEqual(Array(bytes.prefix(16)), start, "\(target) is not a picture")
            XCTAssertEqual(Array(bytes.suffix(8)), [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82], "\(target) is not whole")
            let width = bytes.count < 20 ? 0 : bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
            XCTAssertGreaterThanOrEqual(width, 1600, "\(target) is \(width) pixels wide, too few to read")
            pictures += 1
        }
        XCTAssertEqual(pictures, 3)
    }

    func testEveryFileTheReadmePointsToIsThere() throws {
        let text = prose(try packageText("README.md"))
        var links = 0
        for after in text.components(separatedBy: "](").dropFirst() {
            let target = String(after.prefix { $0 != ")" })
            if target.hasPrefix("http") || target.hasPrefix("#") {
                continue
            }
            XCTAssertTrue(packageHas(target), "the README points to a file that is not there: \(target)")
            links += 1
        }
        XCTAssertGreaterThanOrEqual(links, 10, "the README does not point into the repository")
        // A place in the README that its table of contents names is there.
        let places = text.split(separator: "\n").filter { $0.hasPrefix("#") }.map { anchorOf($0.drop { $0 == "#" }.dropFirst()) }
        for after in text.components(separatedBy: "](#").dropFirst() {
            let anchor = String(after.prefix { $0 != ")" })
            XCTAssertTrue(places.contains(anchor), "the README's contents name a place that is not there: #\(anchor)")
        }
    }

    func testTheReadmesSwiftCodeIsCodeThatIsRun() throws {
        let text = try packageText("README.md")
        // The files that the README's code is taken from: the examples, which
        // the tests run, and the file that says what a store is.
        var sources: [String: [String]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: packageURL("tests/Examples"), includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            sources[file.lastPathComponent] = trimmed(try packageText("tests/Examples/" + file.lastPathComponent))
        }
        XCTAssertGreaterThanOrEqual(sources.count, 5)
        sources["Store.swift"] = trimmed(try packageText("src/Store.swift"))
        let manifest = try packageText("Package.swift")
        var blocks = 0
        for after in text.components(separatedBy: "```swift\n").dropFirst() {
            guard let end = after.range(of: "\n```") else {
                XCTFail("a block of Swift code in the README is not closed")
                continue
            }
            let block = String(after[..<end.lowerBound])
            blocks += 1
            // The lines a reader puts into a manifest of their own are held to
            // this version, and to the names this package gives itself.
            if block.contains(".package(url:") {
                XCTAssertTrue(block.contains("Scionic-MerkleTree-Swift\", from: \"\(Scionic.version)\")"), block)
                XCTAssertTrue(block.contains(".product(name: \"ScionicMerkleTree\", package: \"Scionic-MerkleTree-Swift\")"), block)
                XCTAssertTrue(manifest.contains(".library(name: \"ScionicMerkleTree\""))
                continue
            }
            // A reader's own program has its code at the top, where an example
            // has it in a test. Every line has to be a line that is compiled,
            // and all of them in one file, in the same order.
            let lines = trimmed(block)
            XCTAssertTrue(
                sources.values.contains { inOrder(lines, $0) },
                "a block of Swift code in the README is in none of the files that are compiled:\n\(block)"
            )
        }
        XCTAssertGreaterThanOrEqual(blocks, 8, "the README shows \(blocks) blocks of Swift code")
        // The check has teeth: a line that no file has is found out, and so are
        // lines out of their order.
        let quickStart = sources["QuickStart.swift"] ?? []
        XCTAssertTrue(inOrder(["let store = MemoryStore()", "print(root) // bafkrei..."], quickStart))
        XCTAssertFalse(inOrder(["let store = MemoryStore()", "no file has this line"], quickStart))
        XCTAssertFalse(inOrder(["print(root) // bafkrei...", "let store = MemoryStore()"], quickStart))
    }
}
