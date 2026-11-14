// Folders held open: what is in one is made, listed and opened from the folder
// itself, one name at a time, and never through a link.

import Foundation
import XCTest
@testable import ScionicMerkleTree
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

private func utf8(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// What a held folder lists: each name, and what it is.
private func kinds(_ held: Held) throws -> [String] {
    try held.list().map { "\($0.raw) \($0.found)" }.sorted()
}

private func readAll(_ source: any ByteSource) throws -> [UInt8] {
    var all: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = try buffer.withUnsafeMutableBytes { try source.read(into: $0) }
        if count == 0 {
            return all
        }
        all += buffer[..<count]
    }
}

/// The text of the file `name` in a held folder.
private func readIn(_ held: Held, _ name: String) throws -> String {
    String(decoding: try readAll(held.openFile(utf8(name))), as: UTF8.self)
}

/// What became of opening something in a held folder: "opened", or why not.
private func outcome<T>(_ open: () throws -> T) -> String {
    do {
        _ = try open()
        return "opened"
    } catch Refused.link {
        return "link"
    } catch Refused.other {
        return "other"
    } catch Refused.failure {
        return "failure"
    } catch {
        return "not a refusal: \(error)"
    }
}

final class DiskTests: XCTestCase {
    func testWhatIsInAHeldFolderIsMadeListedAndOpened() throws {
        let scratch = try TempDir("disk-made")
        let top = try Held.create(scratch.join("top"))
        XCTAssertThrowsError(try Held.create(scratch.join("top")), "a taken place")
        XCTAssertEqual(top.path, scratch.join("top"))
        let inner = try top.createFolder(utf8("inner"))
        try top.createFile(utf8("file")).write(bytes("bytes"))
        try inner.createFile(utf8("deep")).write(bytes("deeper"))
        // Nothing is made where something is.
        XCTAssertThrowsError(try top.createFile(utf8("file")))
        XCTAssertThrowsError(try top.createFile(utf8("inner")))
        XCTAssertThrowsError(try top.createFolder(utf8("inner")))
        XCTAssertThrowsError(try top.createFolder(utf8("file")))
        XCTAssertEqual(try kinds(top), ["file file", "inner folder"])
        XCTAssertEqual(try readIn(top, "file"), "bytes")
        let again = try Held.open(scratch.join("top")).openFolder(utf8("inner"))
        XCTAssertEqual(try readIn(again, "deep"), "deeper")
        // One kind of thing is not opened as the other.
        XCTAssertEqual(outcome { try top.openFile(utf8("inner")) }, "other")
        XCTAssertEqual(outcome { try top.openFolder(utf8("file")) }, "other")
        XCTAssertEqual(outcome { try top.openFile(utf8("absent")) }, "failure")
        XCTAssertEqual(outcome { try top.openFolder(utf8("absent")) }, "failure")
    }

    func testANameIsOneName() throws {
        let scratch = try TempDir("disk-one-name")
        let top = try Held.create(scratch.join("top"))
        let inner = try top.createFolder(utf8("inner"))
        try writeFile(scratch.join("beside"), bytes("beside"))
        var moreThanAName = ["", ".", "..", "../beside", "inner/new", "a\0b"]
        #if os(Windows)
        moreThanAName += ["..\\beside", "inner\\new", "file:stream", "C:new"]
        #endif
        for bad in moreThanAName {
            XCTAssertEqual(outcome { try top.openFile(utf8(bad)) }, "failure", bad)
            XCTAssertEqual(outcome { try inner.openFolder(utf8(bad)) }, "failure", bad)
            XCTAssertThrowsError(try top.createFile(utf8(bad)), bad)
            XCTAssertThrowsError(try inner.createFolder(utf8(bad)), bad)
        }
        // Nothing was made, in the folders or beside them.
        XCTAssertEqual(try kinds(top), ["inner folder"])
        XCTAssertEqual(try kinds(inner), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count, 2)
    }

    #if !os(Windows)
    func testALinkIsRefusedWhereverItStands() throws {
        let scratch = try TempDir("disk-links")
        let root = scratch.path
        try writeFile(root + "/secret/key", bytes("secret"))
        try writeFile(root + "/top/real/file", bytes("mine"))
        XCTAssertEqual(symlink(root + "/secret", root + "/top/to-folder"), 0)
        XCTAssertEqual(symlink(root + "/secret/key", root + "/top/to-file"), 0)
        XCTAssertEqual(symlink(root + "/nowhere", root + "/top/to-nothing"), 0)
        let top = try Held.open(root + "/top")
        XCTAssertEqual(try kinds(top), ["real folder", "to-file link", "to-folder link", "to-nothing link"])
        XCTAssertEqual(outcome { try top.openFolder(utf8("to-folder")) }, "link")
        XCTAssertEqual(outcome { try top.openFile(utf8("to-file")) }, "link")
        XCTAssertEqual(outcome { try top.openFile(utf8("to-folder")) }, "link")
        XCTAssertEqual(outcome { try top.openFile(utf8("to-nothing")) }, "link")
        // Nothing is made through a link, or in the place of one.
        XCTAssertThrowsError(try top.createFile(utf8("to-nothing")))
        XCTAssertThrowsError(try top.createFolder(utf8("to-nothing")))
        XCTAssertThrowsError(try top.createFile(utf8("to-folder")))
        XCTAssertFalse(existsAt(root + "/nowhere"))

        // A folder that is held stays the folder it was, whatever becomes of its
        // name: here the name is given to a link that leads elsewhere.
        let real = try top.openFolder(utf8("real"))
        try FileManager.default.moveItem(atPath: root + "/top/real", toPath: root + "/top/moved")
        XCTAssertEqual(symlink(root + "/secret", root + "/top/real"), 0)
        try writeFile(root + "/secret/file", bytes("not mine"))
        XCTAssertEqual(try readIn(real, "file"), "mine")
        XCTAssertEqual(outcome { try top.openFolder(utf8("real")) }, "link")
        // What is made in it lands in it, and not where the link leads.
        _ = try real.createFile(utf8("new"))
        XCTAssertTrue(existsAt(root + "/top/moved/new"))
        XCTAssertFalse(existsAt(root + "/secret/new"))

        // The place a caller names is the caller's, link or not.
        XCTAssertEqual(symlink(root + "/top", root + "/alias"), 0)
        let alias = try Held.open(root + "/alias")
        XCTAssertEqual(outcome { try alias.openFolder(utf8("moved")) }, "opened")

        // A pipe that took a file's place is refused, and not waited on.
        if mkfifo(root + "/top/pipe", 0o600) == 0 {
            XCTAssertEqual(outcome { try top.openFile(utf8("pipe")) }, "other")
        }
    }
    #endif

    #if os(Windows)
    func testAFolderThatIsHeldCanBeNeitherRenamedNorReplaced() throws {
        let scratch = try TempDir("disk-pinned")
        let root = scratch.path
        try writeFile(root + "/top/a/b/file", bytes("mine"))
        try FileManager.default.createDirectory(atPath: root + "/top/a/empty", withIntermediateDirectories: true)
        do {
            let b: Held
            let empty: Held
            do {
                let top = try Held.open(root + "/top")
                let a = try top.openFolder(utf8("a"))
                b = try a.openFolder(utf8("b"))
                empty = try a.openFolder(utf8("empty"))
            }
            // The lower folders keep the ones above them held.
            try withExtendedLifetime((b, empty)) {
                XCTAssertThrowsError(try FileManager.default.moveItem(atPath: root + "/top/a/b", toPath: root + "/top/a/c"))
                XCTAssertThrowsError(try FileManager.default.moveItem(atPath: root + "/top/a", toPath: root + "/top/z"))
                XCTAssertThrowsError(try FileManager.default.moveItem(atPath: root + "/top", toPath: root + "/gone"))
                XCTAssertFalse(RemoveDirectoryW(try verbatim(root + "/top/a/empty")))
                XCTAssertEqual(try readIn(b, "file"), "mine")
            }
        }
        // Let go of, they are anyone's again.
        XCTAssertTrue(RemoveDirectoryW(try verbatim(root + "/top/a/empty")))
        try FileManager.default.moveItem(atPath: root + "/top/a", toPath: root + "/top/z")
    }

    func testALinkBetweenFoldersIsRefused() throws {
        let scratch = try TempDir("disk-junction")
        let root = scratch.path
        try writeFile(root + "/secret/key", bytes("secret"))
        try FileManager.default.createDirectory(atPath: root + "/top/real", withIntermediateDirectories: true)
        // A link from one folder to another, of the kind that anyone may make.
        guard linkToFolder(root + "/top/to-folder", root + "/secret") else {
            throw XCTSkip("this system would not make a link between folders")
        }
        do {
            let top = try Held.open(root + "/top")
            XCTAssertEqual(try kinds(top), ["real folder", "to-folder link"])
            XCTAssertEqual(outcome { try top.openFolder(utf8("to-folder")) }, "link")
            XCTAssertEqual(outcome { try top.openFile(utf8("to-folder")) }, "link")
            XCTAssertThrowsError(try top.createFile(utf8("to-folder")))
            XCTAssertThrowsError(try top.createFolder(utf8("to-folder")))
        }
        // The link is taken away as a link: what it leads to stays.
        XCTAssertTrue(RemoveDirectoryW(try verbatim(root + "/top/to-folder")))
        XCTAssertFalse(existsAt(root + "/top/to-folder"))
        XCTAssertTrue(existsAt(root + "/secret/key"))
    }

    func testANameIsOpenedAsItIsListed() throws {
        let scratch = try TempDir("disk-names")
        // A path that begins with `\\?\` is taken letter for letter, so it can make
        // the names that Windows changes when it looks an ordinary path up: a dot
        // or a space at the end goes, and some names are devices.
        let exact = try exactPath(scratch.join("top"))
        XCTAssertTrue(String(decoding: exact, as: UTF16.self).hasPrefix("\\\\?\\"))
        func inTop(_ names: String...) -> [UInt16] {
            exact + names.flatMap { [0x5C] + Array($0.utf16) } + [0]
        }
        try makeFolderExact(exact + [0])
        let files = ["a", "a.", "a ", "only.", "aux", "nul", "con", "com1", "nul.txt"]
        let folders = ["d", "d.", "d ", "...", ".. "]
        for file in files {
            try writeFileExact(inTop(file), bytes("the file [\(file)]"))
        }
        for folder in folders {
            try makeFolderExact(inTop(folder))
            try writeFileExact(inTop(folder, "inside"), bytes("in [\(folder)]"))
        }

        let top = try Held.open(scratch.join("top"))
        XCTAssertEqual(try top.list().count, files.count + folders.count)
        for file in files {
            XCTAssertEqual(try readIn(top, file), "the file [\(file)]")
            XCTAssertThrowsError(try top.createFile(utf8(file)), "\(file) is taken")
        }
        for folder in folders {
            do {
                let held = try top.openFolder(utf8(folder))
                try withExtendedLifetime(held) {
                    XCTAssertEqual(try kinds(held), ["inside file"])
                    XCTAssertEqual(try readIn(held, "inside"), "in [\(folder)]")
                    // It is this folder that is held, and not the one that Windows
                    // would have made of its name.
                    XCTAssertFalse(MoveFileW(inTop(folder), inTop("moved")), folder)
                }
            }
            XCTAssertTrue(MoveFileW(inTop(folder), inTop("moved")), folder)
            XCTAssertTrue(MoveFileW(inTop("moved"), inTop(folder)), folder)
        }
        // What is made is made under the name it is given, and under no other.
        let made = try top.createFolder(utf8("made."))
        try made.createFile(utf8("file ")).write(bytes("new"))
        XCTAssertEqual(try kinds(made), ["file  file"])
        XCTAssertEqual(try readFileExact(inTop("made.", "file ")), bytes("new"))
        XCTAssertFalse(existsExact(inTop("made")))
    }

    func testNothingIsMadeThroughALinkThatLeadsNowhere() throws {
        let scratch = try TempDir("disk-nowhere")
        let root = scratch.path
        try FileManager.default.createDirectory(atPath: root + "/top", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/elsewhere", withIntermediateDirectories: true)
        // Links between folders, of the kind that anyone may make, to places where
        // nothing is: each is made to a folder, which is then taken away.
        var links: [String] = []
        for link in ["one", "two"] {
            let to = root + "/elsewhere/" + link
            try FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: false)
            let made = linkToFolder(root + "/top/" + link, to)
            XCTAssertTrue(RemoveDirectoryW(try verbatim(to)))
            if made {
                links.append(link)
            }
        }
        // Links of the other kind, which take a right that not every account has.
        if linkToFile(root + "/top/three", root + "/elsewhere/three") {
            links.append("three")
        }
        if try symlinkToFolder(root + "/top/four", root + "/elsewhere/four") {
            links.append("four")
        }
        let top = try Held.open(root + "/top")
        XCTAssertEqual(try top.list().count, links.count)
        for link in links {
            XCTAssertThrowsError(try top.createFile(utf8(link)), link)
            XCTAssertThrowsError(try top.createFolder(utf8(link)), link)
            XCTAssertEqual(outcome { try top.openFile(utf8(link)) }, "link", link)
            XCTAssertEqual(outcome { try top.openFolder(utf8(link)) }, "link", link)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root + "/elsewhere").count, 0)
    }

    func testTwoOpenFilesAreKnownToBeOneFileOrNot() throws {
        let scratch = try TempDir("disk-identity")
        let root = scratch.path
        for file in ["one", "two", "folder/one"] {
            try writeFile(root + "/" + file, bytes("one"))
        }
        func same(_ left: String, _ right: String) throws -> Bool {
            let (first, second) = (try openFileAt(root + "/" + left), try openFileAt(root + "/" + right))
            // Both ways of telling files apart agree, where both are to be had.
            let one = left == right || right.hasPrefix("link-to-" + left)
            for long in [true, false] {
                if let firstIs = try? first.identity(long: long), let secondIs = try? second.identity(long: long) {
                    XCTAssertEqual(firstIs == secondIs, one, "\(left) and \(right), long: \(long)")
                }
            }
            return try sameFile(first, second)
        }
        XCTAssertTrue(try same("one", "one"))
        // Two files with the same bytes are two files, and so are two files with
        // the same name in two folders.
        XCTAssertFalse(try same("one", "two"))
        XCTAssertFalse(try same("one", "folder/one"))
        // A second name of a file is the file.
        if CreateHardLinkW(try verbatim(root + "/link-to-one-hard"), try verbatim(root + "/one"), nil) {
            XCTAssertTrue(try same("one", "link-to-one-hard"))
        }
        // What a link leads to is the file it leads to, and no other: a link that
        // took a file's place is found by this.
        if linkToFile(root + "/link-to-one", root + "/one") {
            XCTAssertTrue(try same("one", "link-to-one"))
            XCTAssertFalse(try same("two", "link-to-one"))
        }
    }

    func testAFileThatSomethingStandsInForIsOpenedAsThatFileOrNotAtAll() throws {
        let scratch = try TempDir("disk-stand-in")
        let root = scratch.path
        try writeFile(root + "/top/plain", bytes("plain"))
        try writeFile(root + "/top/stood-in", bytes("stood in for"))
        guard try standInFor(root + "/top/stood-in") else {
            throw XCTSkip("this system would not let anything stand in for a file")
        }
        do {
            let top = try Held.open(root + "/top")
            // It is a file, and no link: nothing says that it leads anywhere.
            XCTAssertEqual(try kinds(top), ["plain file", "stood-in file"])
            XCTAssertEqual(try readIn(top, "plain"), "plain")
            // Nothing on this machine reads it, so it is not opened. It is the system
            // that says so, and nothing is read by another way.
            XCTAssertEqual(outcome { try top.openFile(utf8("stood-in")) }, "failure")
        }
        // It is not built into a tree either, and the error names it.
        let error = assertFails(try build(MemoryStore(), path: root + "/top", options: smallOptions()), "io")
        if case let .io(_, path, _)? = error {
            XCTAssertTrue(path.hasSuffix("stood-in"), path)
        }
        // And it is still a file that can be taken away.
        XCTAssertTrue(DeleteFileW(try verbatim(root + "/top/stood-in")))
    }
    #endif
}
