import Foundation
@testable import speed
import XCTest

final class SpeedTests: XCTestCase {
    // The example is run, so that it cannot fall behind the library. The roots
    // it prints are the ones that the Rust and Go libraries' examples print for
    // a file of the same size: all three make the same bytes, and all three have
    // to chunk and hash them the same way.
    func testTheExamplePrintsTheRootsThatTheRustLibrarysDoes() throws {
        let temp = try TempDir("speed")
        try writeFile(temp.join("notes.md"), Array("# Notes\n".utf8))
        let sized: [(megabytes: Int, printed: [String])] = [
            (8, [" 5 chunks\n", "root bafkreihlmar6at4go4edps64trfo7nmddh6i3lyd6ibuhiqwjvxohnorqu (74)\n"]),
            (0, [" 0 chunks\n", "root bafkreihfnyssmxyxarhaixuy77kzg4u6dkyc55az74s5npkmsb3xdh6ryu (00)\n"]),
        ]
        for (megabytes, printed) in sized {
            var out = ""
            let root = try speed(megabytes, temp.path, to: &out)
            let wanted = printed + [
                "chunked ", "hashed ", "built ", "checked ", "root \(root)",
                "built from disk ", " 1 different files, 8 bytes\n",
            ]
            for want in wanted {
                XCTAssertTrue(out.contains(want), "\(megabytes) MiB: the example did not print \(want):\n\(out)")
            }
        }
    }

    func testTheFillerIsTheSameBytesEveryTime() {
        let long = filler(1000)
        XCTAssertEqual(long.count, 1000)
        XCTAssertEqual(filler(0), [])
        // A shorter filling is the start of a longer one, wherever it is cut off.
        for length in [1, 7, 8, 9, 999] {
            XCTAssertEqual(filler(length), Array(long[..<length]), "\(length) bytes of filler are not the first \(length) of 1000")
        }
        // The generator's first step, low byte first, as it was worked out by
        // hand: 0x9E3779B97F4A7C15 through its three shifts.
        XCTAssertEqual(Array(long[..<8]), [0xad, 0x4d, 0xf3, 0x0b, 0xae, 0x77, 0x1b, 0xdc])
    }
}
