import Foundation
import ScionicMerkleTree
import XCTest

/// The bytes of a file, in order.
final class FileSource: ByteSource {
    let file: FileHandle

    init(_ file: FileHandle) {
        self.file = file
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        // At the end of the file there is nothing more: zero bytes.
        guard let bytes = try file.read(upToCount: buffer.count) else {
            return 0
        }
        return bytes.copyBytes(to: buffer)
    }
}

/// Bytes written to a file, in order.
final class FileSink: ByteSink {
    let file: FileHandle

    init(_ file: FileHandle) {
        self.file = file
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try file.write(contentsOf: Data(bytes))
    }
}

final class BundlesAndChangesExample: XCTestCase {
    // A whole tree can travel as one stream, and two trees in one store can be
    // compared.
    func testBundlesAndChanges() throws {
        var printed: [String] = []
        func print(_ items: Any...) {
            printed.append(items.map { "\($0)" }.joined(separator: " "))
        }
        // The example works in a folder of its own, which holds two releases.
        let undo = try workIn([
            "release-1/README.md": Array("# My model\n".utf8),
            "release-1/weights.bin": [UInt8](repeating: 7, count: 3 << 20),
            "release-2/README.md": Array("# My model, improved\n".utf8),
            "release-2/weights.bin": [UInt8](repeating: 7, count: 3 << 20),
            "release-2/LICENSE": Array("MIT\n".utf8),
        ])
        defer { undo() }

        let store = MemoryStore()
        let older = try build(store, path: "release-1")
        let newer = try build(store, path: "release-2")

        // What changed, by path. The chunks that both releases share are held once.
        for change in try diff(store, old: older, new: newer) {
            print(change.path)
        }

        // The new release as one file: the record, then every list and every
        // chunk once.
        try Data().write(to: URL(fileURLWithPath: "release-2.bundle"))
        let bundle = try FileHandle(forWritingTo: URL(fileURLWithPath: "release-2.bundle"))
        try exportBundle(store, newer, to: FileSink(bundle))
        try bundle.close()

        // Reading it back runs the same checks as a fetch from a peer.
        let reading = try FileHandle(forReadingFrom: URL(fileURLWithPath: "release-2.bundle"))
        let elsewhere = MemoryStore()
        let summary = try importBundle(elsewhere, newer, from: FileSource(reading))
        try reading.close()
        print(summary.files, "files arrived")

        XCTAssertEqual(printed, ["LICENSE", "README.md", "3 files arrived"])
    }
}
