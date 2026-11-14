// Files that Windows cannot reach by an ordinary path, for the tests that make
// them: a name that ends in a dot or a space, or one that is a device's.

#if os(Windows)
import WinSDK
@testable import ScionicMerkleTree

/// `path` in the form that Windows takes letter for letter, ended by a zero.
func verbatim(_ path: String) throws -> [UInt16] {
    try exactPath(path) + [0]
}

/// Makes the folder at `path`, a path that Windows takes letter for letter.
/// One that is there already is let be.
func makeFolderExact(_ path: [UInt16]) throws {
    if !CreateDirectoryW(path, nil) && GetLastError() != DWORD(ERROR_ALREADY_EXISTS) {
        throw TestFailure("could not make a folder: error \(GetLastError())")
    }
}

/// Writes the file at `path`, a path that Windows takes letter for letter.
func writeFileExact(_ path: [UInt16], _ bytes: [UInt8]) throws {
    let handle = CreateFileW(path, DWORD(0x4000_0000), 0, nil, DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
    guard let handle, Int(bitPattern: handle) != -1 else {
        throw TestFailure("could not make a file: error \(GetLastError())")
    }
    defer { CloseHandle(handle) }
    var written: DWORD = 0
    if !bytes.isEmpty && !WriteFile(handle, bytes, DWORD(bytes.count), &written, nil) {
        throw TestFailure("could not write a file: error \(GetLastError())")
    }
}

/// Removes the folder at `path` and everything in it, names that Windows cannot
/// reach by an ordinary path too.
func removeExact(_ path: String) {
    guard let exact = try? exactPath(path) else {
        return
    }
    removeExact(exact)
}

private func removeExact(_ path: [UInt16]) {
    var data = WIN32_FIND_DATAW()
    let pattern = path + Array("\\*".utf16) + [0]
    if let search = FindFirstFileW(pattern, &data), Int(bitPattern: search) != -1 {
        repeat {
            let name: [UInt16] = withUnsafeBytes(of: &data.cFileName) { raw in
                Array(raw.bindMemory(to: UInt16.self).prefix { $0 != 0 })
            }
            if name == [0x2E] || name == [0x2E, 0x2E] {
                continue
            }
            let child = path + [0x5C] + name
            let isLink = data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
            if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                if isLink {
                    _ = RemoveDirectoryW(child + [0])
                } else {
                    removeExact(child)
                }
            } else {
                _ = DeleteFileW(child + [0])
            }
        } while FindNextFileW(search, &data)
        FindClose(search)
    }
    _ = RemoveDirectoryW(path + [0])
}

/// The bytes of the file at `path`, a path that Windows takes letter for letter,
/// ended by a zero.
func readFileExact(_ path: [UInt16]) throws -> [UInt8] {
    let handle = CreateFileW(path, DWORD(0x8000_0000), DWORD(1 | 2 | 4), nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
    guard let handle, Int(bitPattern: handle) != -1 else {
        throw TestFailure("could not open a file: error \(GetLastError())")
    }
    defer { CloseHandle(handle) }
    var all: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        var read: DWORD = 0
        if !ReadFile(handle, &buffer, DWORD(buffer.count), &read, nil) {
            throw TestFailure("could not read a file: error \(GetLastError())")
        }
        if read == 0 {
            return all
        }
        all += buffer[..<Int(read)]
    }
}

/// Whether anything is at `path`, a path that Windows takes letter for letter,
/// ended by a zero.
func existsExact(_ path: [UInt16]) -> Bool {
    GetFileAttributesW(path) != DWORD(0xFFFF_FFFF)
}

/// Makes a link at `link` that leads to the folder `to`, of the kind that takes
/// a right that not every account has. `to` need not be there. Says whether the
/// system made it.
func symlinkToFolder(_ link: String, _ to: String) throws -> Bool {
    // A link to a folder, made by an account without the right where Windows
    // lets it.
    CreateSymbolicLinkW(try verbatim(link), try verbatim(to), DWORD(0x1 | 0x2)) != 0
}

/// Makes something stand in for a file, as a system does that fetches a file's
/// bytes when they are read. Nothing on this machine knows what to do with this
/// one, which is what makes it safe to put there. Says whether the system let it
/// be put there.
func standInFor(_ path: String) throws -> Bool {
    // To write, sharing everything, opened as itself.
    let handle = CreateFileW(try verbatim(path), DWORD(0x4000_0000), DWORD(1 | 2 | 4), nil, DWORD(OPEN_EXISTING), DWORD(0x0020_0000), nil)
    guard let handle, Int(bitPattern: handle) != -1 else {
        throw TestFailure("could not open a file: error \(GetLastError())")
    }
    defer { CloseHandle(handle) }
    // A tag that is nobody's, with its 16 bytes of identity and four bytes of
    // data: the tag, the data's length, two bytes that are kept free, the
    // identity, and the data.
    var buffer: [UInt8] = [0x51, 0x7C, 0x00, 0x00, 4, 0, 0, 0]
    buffer += Array("scionic-test-tag".utf8)
    buffer += [1, 2, 3, 4]
    var returned: DWORD = 0
    return buffer.withUnsafeMutableBytes { raw in
        // FSCTL_SET_REPARSE_POINT
        DeviceIoControl(handle, DWORD(0x0009_00A4), raw.baseAddress, DWORD(raw.count), nil, 0, &returned, nil)
    }
}
#endif
