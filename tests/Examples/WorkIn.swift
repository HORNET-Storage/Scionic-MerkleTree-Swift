import Foundation
import XCTest

/// Makes a new folder with these files in it, and makes it the folder that the
/// program works in, so that an example can name its files as a reader of it
/// would. It gives back what undoes both.
///
/// The tests are run one after another, so nothing else is at work while the
/// folder is another one.
func workIn(_ files: [String: [UInt8]]) throws -> () -> Void {
    let was = FileManager.default.currentDirectoryPath
    let work = try TempDir("example")
    for (name, content) in files {
        try writeFile(work.join(name), content)
    }
    guard FileManager.default.changeCurrentDirectoryPath(work.path) else {
        throw TestFailure("could not work in \(work.path)")
    }
    return {
        if !FileManager.default.changeCurrentDirectoryPath(was) {
            XCTFail("could not go back to \(was)")
        }
        // The folder is removed once it is let go, which is here.
        withExtendedLifetime(work) {}
    }
}
