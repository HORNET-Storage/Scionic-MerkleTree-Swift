// Links, for the tests that hold the library to never following one.

import Foundation
#if os(Windows)
import WinSDK
#endif

/// Makes a link at `link` that leads to the folder `to`, of the kind that anyone
/// may make: on Windows a junction. Says whether the system made it.
func linkToFolder(_ link: String, _ to: String) -> Bool {
    #if os(Windows)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe")
    process.arguments = ["/C", "mklink", "/J", backslashed(link), backslashed(to)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
    #else
    return (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: to)) != nil
    #endif
}

/// Makes a link at `link` that leads to the file `to`. Says whether the system
/// made it: on Windows that takes a right that not every account has.
func linkToFile(_ link: String, _ to: String) -> Bool {
    (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: to)) != nil
}

/// Removes a link, and never what it leads to.
func removeLink(_ path: String) {
    #if os(Windows)
    _ = backslashed(path).withCString(encodedAs: UTF16.self) { path in
        RemoveDirectoryW(path) || DeleteFileW(path)
    }
    #else
    _ = unlink(path)
    #endif
}

/// Whether there is a folder at `path`, a link to one counted.
func isFolder(_ path: String) -> Bool {
    var folder: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
}

/// Whether there is a file at `path`, a link to one counted.
func isFile(_ path: String) -> Bool {
    var folder: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
}

#if os(Windows)
private func backslashed(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: "\\")
}
#endif
