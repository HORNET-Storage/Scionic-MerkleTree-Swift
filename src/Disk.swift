// Folders on disk, held open.
//
// A path is looked up afresh every time it is used. Whoever can write to a
// folder on the way can swap it for a link between two uses, and send the
// second use somewhere else. So nothing here is reached by its whole path but
// the one place a caller names. From there on a folder is held open, and what
// is in it is reached from the folder itself, one name at a time, and never
// through a link.
//
// * On Linux and Apple's systems a held folder is an open descriptor. What is
//   in it is opened from that descriptor, with links refused by the system
//   itself.
// * On Windows a held folder is a handle that does not share deletion. The
//   folder can be neither renamed nor replaced while it is held, and a held
//   folder keeps the folders above it held. What is in it is opened by its
//   path, as itself, and refused when it turns out to be a link. The path is
//   in the form that Windows takes letter for letter, so a name is the name
//   that was listed and no other.
//
// On every system a name is one name: an empty one, a dot name, or one with a
// separator in it is refused before the system sees it.

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// What a name in a folder is, without following it.
enum Found: Equatable {
    case file
    case folder
    case link
    case other
}

/// Why something in a held folder was not opened.
enum Refused: Error {
    /// A link is there.
    case link
    /// Something other than what was asked for is there.
    case other
    /// The system said no.
    case failure(SystemFailure)
}

/// The separator a path is joined with, for messages.
#if os(Windows)
let pathSeparator = "\\"
#else
let pathSeparator = "/"
#endif

/// `name` in the folder at `path`, for messages: nothing is opened by it.
func joined(_ path: String, _ name: String) -> String {
    path.hasSuffix("/") || path.hasSuffix(pathSeparator) ? path + name : path + pathSeparator + name
}

/// A name in a folder is one name. One that could lead out of the folder, or to
/// a part of a file, is refused before the system sees it: an empty name, a dot
/// name, and a name with a separator or a zero byte in it. On Windows a colon
/// too, which names a second stream of a file's bytes.
private func oneName(_ name: [UInt8]) throws -> [UInt8] {
    var moreThanAName = name.isEmpty || name == [0x2E] || name == [0x2E, 0x2E] || name.contains(0x2F) || name.contains(0)
    #if os(Windows)
    moreThanAName = moreThanAName || name.contains(0x5C) || name.contains(0x3A)
    #endif
    if moreThanAName {
        throw SystemFailure(kind: .other, code: 0, message: "what is opened or made in a folder is named by one name")
    }
    return name
}

// MARK: - Files

/// A file that is open, to read or to write.
final class DiskFile: ByteSource, ByteSink {
    #if os(Windows)
    private let handle: HANDLE
    init(handle: HANDLE) {
        self.handle = handle
    }
    #else
    private let fd: Int32
    init(fd: Int32) {
        self.fd = fd
    }
    #endif

    deinit {
        #if os(Windows)
        _ = CloseHandle(handle)
        #else
        _ = close(fd)
        #endif
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if buffer.isEmpty {
            return 0
        }
        #if os(Windows)
        var read: DWORD = 0
        let asked = DWORD(min(buffer.count, 1 << 30))
        if !ReadFile(handle, buffer.baseAddress, asked, &read, nil) {
            let code = GetLastError()
            // A pipe whose other end is gone has ended.
            if code == DWORD(ERROR_BROKEN_PIPE) || code == DWORD(ERROR_HANDLE_EOF) {
                return 0
            }
            throw systemFailure(code)
        }
        return Int(read)
        #else
        while true {
            let count = Glibc_or_Darwin_read(fd, buffer.baseAddress, buffer.count)
            if count >= 0 {
                return count
            }
            if errno != EINTR {
                throw systemFailure(errno)
            }
        }
        #endif
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            #if os(Windows)
            var written: DWORD = 0
            let asked = DWORD(min(bytes.count - done, 1 << 30))
            if !WriteFile(handle, bytes.baseAddress! + done, asked, &written, nil) {
                throw systemFailure(GetLastError())
            }
            if written == 0 {
                throw SystemFailure(kind: .other, code: 0, message: "the system wrote nothing")
            }
            done += Int(written)
            #else
            let count = Glibc_or_Darwin_write(fd, bytes.baseAddress! + done, bytes.count - done)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw systemFailure(errno)
            }
            if count == 0 {
                throw SystemFailure(kind: .other, code: 0, message: "the system wrote nothing")
            }
            done += count
            #endif
        }
    }

    #if os(Windows)
    /// Which file this is: the volume, and the number of the file on it. The
    /// long form has a 128-bit number, and every volume of the newer kinds has
    /// it. The short form has a 64-bit number, and every volume has it, but ReFS
    /// does not promise that its short number is one file's alone.
    func identity(long: Bool) throws -> FileIdentity {
        if long {
            var info = FILE_ID_INFO()
            if !GetFileInformationByHandleEx(handle, FileIdInfo, &info, DWORD(MemoryLayout<FILE_ID_INFO>.size)) {
                throw systemFailure(GetLastError())
            }
            return FileIdentity(volume: info.VolumeSerialNumber, number: withUnsafeBytes(of: info.FileId.Identifier) { Array($0) })
        }
        var info = BY_HANDLE_FILE_INFORMATION()
        if !GetFileInformationByHandle(handle, &info) {
            throw systemFailure(GetLastError())
        }
        var number: [UInt8] = []
        number.appendU32(info.nFileIndexHigh)
        number.appendU32(info.nFileIndexLow)
        return FileIdentity(volume: UInt64(info.dwVolumeSerialNumber), number: number)
    }
    #endif
}

#if os(Windows)
/// Which file an open file is: a volume, and the number of the file on it.
struct FileIdentity: Equatable {
    let volume: UInt64
    let number: [UInt8]
}

/// Whether two open files are one file. Both are asked in the same form: the
/// long one where both volumes have it, and the short one otherwise. Where a
/// file's identity is not to be had, nothing says that the two are one, and
/// that is an error.
func sameFile(_ left: DiskFile, _ right: DiskFile) throws -> Bool {
    if let leftIs = try? left.identity(long: true), let rightIs = try? right.identity(long: true) {
        return leftIs == rightIs
    }
    return try left.identity(long: false) == right.identity(long: false)
}
#endif

#if !os(Windows)
@inline(__always)
private func Glibc_or_Darwin_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

@inline(__always)
private func Glibc_or_Darwin_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}
#endif

// MARK: - What the system says

#if os(Windows)
/// A failure as Windows numbers it.
func systemFailure(_ code: DWORD) -> SystemFailure {
    let kind: SystemFailure.Kind
    let what: String
    switch Int32(bitPattern: code) {
    case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND:
        kind = .notFound
        what = "it is not there"
    case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS:
        kind = .alreadyExists
        what = "something is there already"
    case ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION:
        kind = .permissionDenied
        what = "Windows did not allow it"
    case ERROR_DIRECTORY:
        kind = .other
        what = "it is not a folder"
    case ERROR_INVALID_NAME:
        kind = .other
        what = "Windows takes no such name"
    default:
        kind = .other
        what = "Windows gave error \(code)"
    }
    return SystemFailure(kind: kind, code: Int32(bitPattern: code), message: what)
}
#else
/// A failure as the system numbers it in `errno`.
func systemFailure(_ code: Int32) -> SystemFailure {
    let kind: SystemFailure.Kind
    switch code {
    case ENOENT:
        kind = .notFound
    case EEXIST:
        kind = .alreadyExists
    case EACCES, EPERM:
        kind = .permissionDenied
    case ELOOP:
        kind = .notAPlainFile
    default:
        kind = .other
    }
    let message = strerror(code).map { String(cString: $0) } ?? "error \(code)"
    return SystemFailure(kind: kind, code: code, message: message)
}
#endif

// MARK: - Held folders

#if os(Windows)

/// Whether `handle` is what CreateFileW and FindFirstFileExW give for a failure.
private func isInvalid(_ handle: HANDLE?) -> Bool {
    handle == nil || Int(bitPattern: handle) == -1
}
private let fileShareRead: DWORD = 0x1
private let fileShareWrite: DWORD = 0x2
private let fileShareDelete: DWORD = 0x4
private let genericRead: DWORD = 0x8000_0000
private let genericWrite: DWORD = 0x4000_0000
private let openExisting: DWORD = 3
private let createNew: DWORD = 1
/// Opens a link as itself, and not what it leads to.
private let fileFlagOpenReparsePoint: DWORD = 0x0020_0000
/// Lets a folder be opened as a file is.
private let fileFlagBackupSemantics: DWORD = 0x0200_0000
private let fileAttributeDirectory: DWORD = 0x10
/// Some part of the system stands in for what is stored here: a link, or a
/// file that is fetched when it is read.
private let fileAttributeReparsePoint: DWORD = 0x400
/// A reparse tag whose point stands for another name: a link or a junction.
private let nameSurrogateBit: DWORD = 0x2000_0000

/// A path in UTF-16, ended by a zero, for the system.
private func wide(_ path: String) -> [UInt16] {
    Array(path.utf16) + [0]
}

/// `path` in the form that Windows takes letter for letter.
///
/// Windows changes an ordinary path when it looks it up: a dot or a space at
/// the end of a name is dropped, and some names are devices wherever they
/// stand. So a file `a.` would be read as the file `a` beside it. A path that
/// begins with `\\?\` is looked up as it is written.
///
/// What the caller wrote is first read the way Windows reads it, which is what
/// the caller means by it. The names that are added to it afterwards are the
/// ones that a folder listed, and are taken as they are.
func exactPath(_ path: String) throws -> [UInt16] {
    let given = wide(path)
    let length = GetFullPathNameW(given, 0, nil, nil)
    if length == 0 {
        throw systemFailure(GetLastError())
    }
    var full = [UInt16](repeating: 0, count: Int(length))
    let written = GetFullPathNameW(given, length, &full, nil)
    if written == 0 || written >= length {
        throw systemFailure(GetLastError())
    }
    full.removeLast(full.count - Int(written))
    let backslash = UInt16(0x5C)
    let verbatim: [UInt16] = Array("\\\\?\\".utf16)
    if full.starts(with: verbatim) {
        // It is in that form already.
        return full
    }
    if full.starts(with: Array("\\\\.\\".utf16)) {
        // `\\.\C:\folder` is `\\?\C:\folder`.
        return verbatim + full.dropFirst(4)
    }
    if full.starts(with: [backslash, backslash]) {
        // `\\server\share\folder` is `\\?\UNC\server\share\folder`.
        return verbatim + Array("UNC\\".utf16) + full.dropFirst(2)
    }
    if full.count >= 3, full[1] == UInt16(0x3A), full[2] == backslash {
        // `C:\folder` is `\\?\C:\folder`.
        return verbatim + full
    }
    return full
}

/// What a handle that was opened as itself is: its attributes and its reparse
/// tag.
private func attributesOf(_ handle: HANDLE) throws -> (attributes: DWORD, tag: DWORD) {
    var info = FILE_ATTRIBUTE_TAG_INFO()
    if !GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &info, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)) {
        throw systemFailure(GetLastError())
    }
    return (info.FileAttributes, info.ReparseTag)
}

private func isLink(_ attributes: DWORD, _ tag: DWORD) -> Bool {
    attributes & fileAttributeReparsePoint != 0 && tag & nameSurrogateBit != 0
}

/// Opens `path`, a path that is exact already.
private func openHandle(_ path: [UInt16], access: DWORD, share: DWORD, disposition: DWORD, flags: DWORD) throws -> HANDLE {
    let handle = CreateFileW(path, access, share, nil, disposition, flags, nil)
    if isInvalid(handle) {
        throw systemFailure(GetLastError())
    }
    return handle!
}

/// Opens the folder at the exact `path` so that it stays what and where it is.
/// Unless `follow` is set, a link is opened as itself, and refused.
private func pin(_ path: [UInt16], follow: Bool) throws(Refused) -> HANDLE {
    let flags = fileFlagBackupSemantics | (follow ? 0 : fileFlagOpenReparsePoint)
    let handle: HANDLE
    do {
        handle = try openHandle(path, access: genericRead, share: fileShareRead | fileShareWrite, disposition: openExisting, flags: flags)
    } catch {
        throw refusedByPath(path, error, wanted: .folder)
    }
    do {
        let (attributes, tag) = try attributesOf(handle)
        if isLink(attributes, tag) {
            _ = CloseHandle(handle)
            throw Refused.link
        }
        if attributes & fileAttributeDirectory == 0 {
            _ = CloseHandle(handle)
            throw Refused.other
        }
    } catch let refused as Refused {
        throw refused
    } catch {
        _ = CloseHandle(handle)
        throw Refused.failure(error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)"))
    }
    return handle
}

/// Why opening `path` failed, for one that had to be `wanted`.
private func refusedByPath(_ path: [UInt16], _ error: any Error, wanted: Found) -> Refused {
    let failure = error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)")
    var data = WIN32_FILE_ATTRIBUTE_DATA()
    guard GetFileAttributesExW(path, GetFileExInfoStandard, &data) else {
        return .failure(failure)
    }
    let attributes = data.dwFileAttributes
    if attributes & fileAttributeReparsePoint != 0 {
        // Which kind of reparse point it is takes a look as itself.
        if let handle = try? openHandle(path, access: 0x80, share: fileShareRead | fileShareWrite | fileShareDelete,
                                        disposition: openExisting, flags: fileFlagBackupSemantics | fileFlagOpenReparsePoint) {
            defer { _ = CloseHandle(handle) }
            if let (attributes, tag) = try? attributesOf(handle), isLink(attributes, tag) {
                return .link
            }
        }
    }
    let isFolder = attributes & fileAttributeDirectory != 0
    if isFolder != (wanted == .folder) {
        return .other
    }
    return .failure(failure)
}

/// Opens the exact `path` as itself, and says whether it is a plain file with
/// nothing standing in for it. A link is refused, and so is a folder.
private func openAsItself(_ path: [UInt16], held: Bool) throws(Refused) -> (HANDLE, Bool) {
    let share = held ? fileShareRead | fileShareWrite : fileShareRead | fileShareWrite | fileShareDelete
    let handle: HANDLE
    do {
        handle = try openHandle(path, access: genericRead, share: share, disposition: openExisting, flags: fileFlagOpenReparsePoint)
    } catch {
        throw refusedByPath(path, error, wanted: .file)
    }
    let found: (attributes: DWORD, tag: DWORD)
    do {
        found = try attributesOf(handle)
    } catch {
        _ = CloseHandle(handle)
        throw Refused.failure(error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)"))
    }
    if isLink(found.attributes, found.tag) {
        _ = CloseHandle(handle)
        throw Refused.link
    }
    if found.attributes & fileAttributeDirectory != 0 {
        _ = CloseHandle(handle)
        throw Refused.other
    }
    return (handle, found.attributes & fileAttributeReparsePoint == 0)
}

/// A folder that is held open.
final class Held: @unchecked Sendable {
    /// Where the folder was when it was opened. For messages: nothing is opened
    /// by this.
    let path: String
    /// The folder's path in the form that Windows takes letter for letter.
    /// Everything in the folder is reached through it.
    private let exact: [UInt16]
    /// Open for as long as the folder is held. It shares reading and writing
    /// and not deleting, so the folder can be neither renamed nor replaced
    /// meanwhile.
    private let pinned: HANDLE
    /// The folder this one is in, held as long as this one is.
    private let above: Held?

    private init(path: String, exact: [UInt16], pinned: HANDLE, above: Held?) {
        self.path = path
        self.exact = exact
        self.pinned = pinned
        self.above = above
    }

    deinit {
        _ = CloseHandle(pinned)
    }

    /// Holds the folder at `path`, as the caller names it: a link on the way to
    /// it, or at its end, is the caller's.
    static func open(_ path: String) throws -> Held {
        let exact = try exactPath(path)
        do {
            return Held(path: path, exact: exact, pinned: try pin(exact + [0], follow: true), above: nil)
        } catch {
            throw asFailure(error)
        }
    }

    /// Makes a new folder at `path`, and holds it. Anything that is there
    /// already is an error.
    static func create(_ path: String) throws -> Held {
        let exact = try exactPath(path)
        if !CreateDirectoryW(exact + [0], nil) {
            throw systemFailure(GetLastError())
        }
        do {
            return Held(path: path, exact: exact, pinned: try pin(exact + [0], follow: false), above: nil)
        } catch {
            throw asFailure(error)
        }
    }

    /// The exact path of `name` in this folder, ended by a zero. The name is
    /// added as it is: nothing reads it as a path.
    private func within(_ name: [UInt8]) throws -> [UInt16] {
        var path = exact
        if path.last != UInt16(0x5C) {
            path.append(UInt16(0x5C))
        }
        path.append(contentsOf: String(decoding: try oneName(name), as: UTF8.self).utf16)
        path.append(0)
        return path
    }

    /// The names in the folder, and what each is. Nothing is followed. A name
    /// that is not UTF-16 comes back as nil.
    func list() throws -> [(name: [UInt8]?, raw: String, found: Found)] {
        var pattern = exact
        if pattern.last != UInt16(0x5C) {
            pattern.append(UInt16(0x5C))
        }
        pattern.append(UInt16(0x2A))
        pattern.append(0)
        var data = WIN32_FIND_DATAW()
        let search = FindFirstFileExW(pattern, FindExInfoBasic, &data, FindExSearchNameMatch, nil, DWORD(2))
        if isInvalid(search) {
            let code = GetLastError()
            if code == DWORD(ERROR_FILE_NOT_FOUND) {
                return []
            }
            throw systemFailure(code)
        }
        defer { _ = FindClose(search) }
        var listed: [(name: [UInt8]?, raw: String, found: Found)] = []
        while true {
            let units: [UInt16] = withUnsafeBytes(of: &data.cFileName) { raw in
                let all = raw.bindMemory(to: UInt16.self)
                return Array(all.prefix { $0 != 0 })
            }
            let dot = UInt16(0x2E)
            if units != [dot] && units != [dot, dot] {
                let text = String(decoding: units, as: UTF16.self)
                let isUTF16 = Array(text.utf16) == units
                let found: Found
                if isLink(data.dwFileAttributes, data.dwReserved0) {
                    found = .link
                } else if data.dwFileAttributes & fileAttributeDirectory != 0 {
                    found = .folder
                } else {
                    found = .file
                }
                listed.append((isUTF16 ? Array(text.utf8) : nil, text, found))
            }
            if !FindNextFileW(search, &data) {
                let code = GetLastError()
                if code == DWORD(ERROR_NO_MORE_FILES) {
                    return listed
                }
                throw systemFailure(code)
            }
        }
    }

    /// Holds the folder `name` in this one. A link is refused.
    func openFolder(_ name: [UInt8]) throws(Refused) -> Held {
        let path: [UInt16]
        do {
            path = try within(name)
        } catch {
            throw .failure(error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)"))
        }
        let pinned = try pin(path, follow: false)
        return Held(path: joined(self.path, String(decoding: name, as: UTF8.self)), exact: Array(path.dropLast()), pinned: pinned, above: self)
    }

    /// Opens the file `name` in this folder, to read. A link is refused, and so
    /// is anything that is not a plain file.
    func openFile(_ name: [UInt8]) throws(Refused) -> DiskFile {
        let path: [UInt16]
        do {
            path = try within(name)
        } catch {
            throw .failure(error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)"))
        }
        let (handle, plain) = try openAsItself(path, held: false)
        if plain {
            // For a plain file, opening it as itself is opening it.
            return DiskFile(handle: handle)
        }
        // Something stands in for this file, as for one that is fetched when it
        // is read, and opened as itself it may not read as the file does. So it
        // is held where it is, looked at again, and opened in the usual way
        // while it cannot be renamed or replaced.
        _ = CloseHandle(handle)
        let (heldHandle, _) = try openAsItself(path, held: true)
        let held = DiskFile(handle: heldHandle)
        let usual: DiskFile
        do {
            usual = DiskFile(handle: try openHandle(path, access: genericRead, share: fileShareRead | fileShareWrite | fileShareDelete,
                                                    disposition: openExisting, flags: 0))
            // Holding the file keeps its name on it. It does not keep what
            // stands in for it from being changed into a link, which the usual
            // way of opening then follows. So what was opened has to be the
            // file that is held, and not another one.
            if try !sameFile(held, usual) {
                throw Refused.link
            }
        } catch let refused as Refused {
            throw refused
        } catch {
            throw .failure(error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)"))
        }
        return usual
    }

    /// Makes the new folder `name` in this one, and holds it.
    func createFolder(_ name: [UInt8]) throws -> Held {
        let path = try within(name)
        if !CreateDirectoryW(path, nil) {
            throw systemFailure(GetLastError())
        }
        do {
            let pinned = try pin(path, follow: false)
            return Held(path: joined(self.path, String(decoding: name, as: UTF8.self)), exact: Array(path.dropLast()), pinned: pinned, above: self)
        } catch {
            throw asFailure(error)
        }
    }

    /// Makes the new file `name` in this folder, to write. Anything that is
    /// there already is an error, a link too.
    func createFile(_ name: [UInt8]) throws -> DiskFile {
        // A link that is there under the name is not gone through: the name is
        // taken, and that is an error.
        let handle = try openHandle(try within(name), access: genericWrite, share: fileShareRead | fileShareWrite | fileShareDelete,
                                    disposition: createNew, flags: fileFlagOpenReparsePoint)
        return DiskFile(handle: handle)
    }

    /// Whether anything is under `name` in this folder, a link too. Nothing is
    /// followed.
    func has(_ name: [UInt8]) -> Bool {
        guard let path = try? within(name) else {
            return false
        }
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        return GetFileAttributesExW(path, GetFileExInfoStandard, &data)
    }
}

#else

private func nameFailure(_ error: any Error) -> SystemFailure {
    error as? SystemFailure ?? SystemFailure(kind: .other, code: 0, message: "\(error)")
}

/// `name`, ended by a zero, for the system.
private func withName<T>(_ name: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
    (name + [0]).withUnsafeBufferPointer { bytes in
        bytes.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
    }
}

private let typeMask: UInt32 = 0o170000
private let typeFile: UInt32 = 0o100000
private let typeFolder: UInt32 = 0o040000
private let typeLink: UInt32 = 0o120000

private func found(mode: UInt32) -> Found {
    switch mode & typeMask {
    case typeFile:
        return .file
    case typeFolder:
        return .folder
    case typeLink:
        return .link
    default:
        return .other
    }
}

/// What `name` is now, without following it.
private func look(_ fd: Int32, _ name: [UInt8]) throws -> Found {
    var info = stat()
    let status = withName(name) { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }
    if status != 0 {
        throw systemFailure(errno)
    }
    return found(mode: UInt32(info.st_mode))
}

/// Why an open that refuses links failed. Systems differ in the error they give
/// for a link, so what is there is looked at.
private func refused(_ fd: Int32, _ name: [UInt8], _ code: Int32, wanted: Found) -> Refused {
    switch try? look(fd, name) {
    case .link?:
        return .link
    case let found? where found != wanted:
        return .other
    default:
        return .failure(systemFailure(code))
    }
}

private let folderFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

/// Opens `name` in the folder `fd`, trying again when only interrupted.
private func openIn(_ fd: Int32, _ name: [UInt8], _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
    while true {
        let opened = withName(name) { openat(fd, $0, flags, mode) }
        if opened >= 0 || errno != EINTR {
            return opened
        }
    }
}

/// A folder that is held open.
final class Held: @unchecked Sendable {
    /// Where the folder was when it was opened. For messages: nothing is opened
    /// by this.
    let path: String
    private let fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    deinit {
        _ = close(fd)
    }

    /// Holds the folder at `path`, as the caller names it: a link on the way to
    /// it, or at its end, is the caller's.
    static func open(_ path: String) throws -> Held {
        let fd = openIn(AT_FDCWD, Array(path.utf8), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            throw systemFailure(errno)
        }
        return Held(path: path, fd: fd)
    }

    /// Makes a new folder at `path`, and holds it. Anything that is there
    /// already is an error.
    static func create(_ path: String) throws -> Held {
        let name = Array(path.utf8)
        if withName(name, { mkdirat(AT_FDCWD, $0, 0o777) }) != 0 {
            throw systemFailure(errno)
        }
        let fd = openIn(AT_FDCWD, name, folderFlags)
        if fd < 0 {
            throw systemFailure(errno)
        }
        return Held(path: path, fd: fd)
    }

    /// The names in the folder, and what each is. Nothing is followed. Every
    /// name comes as its bytes.
    func list() throws -> [(name: [UInt8]?, raw: String, found: Found)] {
        // The folder is read through a descriptor of its own, which "." in it
        // gives, so that a second listing starts at the start again.
        let own = openIn(fd, [0x2E], O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if own < 0 {
            throw systemFailure(errno)
        }
        guard let dir = fdopendir(own) else {
            let code = errno
            _ = close(own)
            throw systemFailure(code)
        }
        defer { _ = closedir(dir) }
        var listed: [(name: [UInt8]?, raw: String, found: Found)] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 {
                    throw systemFailure(errno)
                }
                return listed
            }
            let name: [UInt8] = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                Array(raw.prefix { $0 != 0 })
            }
            if name == [0x2E] || name == [0x2E, 0x2E] {
                continue
            }
            let kind: Found
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_REG):
                kind = .file
            case Int32(DT_DIR):
                kind = .folder
            case Int32(DT_LNK):
                kind = .link
            case Int32(DT_UNKNOWN):
                kind = try look(fd, name)
            default:
                kind = .other
            }
            listed.append((name, String(decoding: name, as: UTF8.self), kind))
        }
    }

    /// Holds the folder `name` in this one. A link is refused.
    func openFolder(_ name: [UInt8]) throws(Refused) -> Held {
        let checked: [UInt8]
        do {
            checked = try oneName(name)
        } catch {
            throw .failure(nameFailure(error))
        }
        let opened = openIn(fd, checked, folderFlags)
        if opened < 0 {
            throw refused(fd, checked, errno, wanted: .folder)
        }
        return Held(path: joined(path, String(decoding: name, as: UTF8.self)), fd: opened)
    }

    /// Opens the file `name` in this folder, to read. A link is refused, and so
    /// is anything that is not a plain file.
    func openFile(_ name: [UInt8]) throws(Refused) -> DiskFile {
        let checked: [UInt8]
        do {
            checked = try oneName(name)
        } catch {
            throw .failure(nameFailure(error))
        }
        // Not waiting: a pipe that took the file's place would hold a waiting
        // open for ever. A plain file is read the same either way.
        let opened = openIn(fd, checked, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if opened < 0 {
            throw refused(fd, checked, errno, wanted: .file)
        }
        let file = DiskFile(fd: opened)
        // What was opened is what is read, so it is what has to be a file.
        var info = stat()
        if fstat(opened, &info) != 0 {
            throw .failure(systemFailure(errno))
        }
        if found(mode: UInt32(info.st_mode)) != .file {
            throw .other
        }
        return file
    }

    /// Makes the new folder `name` in this one, and holds it.
    func createFolder(_ name: [UInt8]) throws -> Held {
        let checked = try oneName(name)
        if withName(checked, { mkdirat(fd, $0, 0o777) }) != 0 {
            throw systemFailure(errno)
        }
        let opened = openIn(fd, checked, folderFlags)
        if opened < 0 {
            throw systemFailure(errno)
        }
        return Held(path: joined(path, String(decoding: name, as: UTF8.self)), fd: opened)
    }

    /// Makes the new file `name` in this folder, to write. Anything that is
    /// there already is an error, a link too.
    func createFile(_ name: [UInt8]) throws -> DiskFile {
        let checked = try oneName(name)
        let opened = openIn(fd, checked, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        if opened < 0 {
            throw systemFailure(errno)
        }
        return DiskFile(fd: opened)
    }

    /// Whether anything is under `name` in this folder, a link too. Nothing is
    /// followed.
    func has(_ name: [UInt8]) -> Bool {
        guard let checked = try? oneName(name) else {
            return false
        }
        return (try? look(fd, checked)) != nil
    }
}

#endif

/// A refusal as a failure of the system, for a place where it is one.
func asFailure(_ error: any Error) -> any Error {
    switch error {
    case Refused.link:
        return SystemFailure(kind: .notAPlainFile, code: 0, message: "a link is there, where a folder has to be")
    case Refused.other:
        return SystemFailure(kind: .notAPlainFile, code: 0, message: "something that is no folder is there, where a folder has to be")
    case let Refused.failure(failure):
        return failure
    default:
        return error
    }
}

/// Opens the file at `path` as the caller names it, to read.
func openFileAt(_ path: String) throws -> DiskFile {
    #if os(Windows)
    let exact = try exactPath(path) + [0]
    return DiskFile(handle: try openHandle(exact, access: genericRead, share: fileShareRead | fileShareWrite | fileShareDelete,
                                           disposition: openExisting, flags: 0))
    #else
    let fd = openIn(AT_FDCWD, Array(path.utf8), O_RDONLY | O_CLOEXEC)
    if fd < 0 {
        throw systemFailure(errno)
    }
    return DiskFile(fd: fd)
    #endif
}

/// Makes the new file at `path`, as the caller names it, to write. Anything
/// that is there already is an error, a link too: it is not gone through.
func createFileAt(_ path: String) throws -> DiskFile {
    #if os(Windows)
    let exact = try exactPath(path) + [0]
    return DiskFile(handle: try openHandle(exact, access: genericWrite, share: fileShareRead | fileShareWrite | fileShareDelete,
                                           disposition: createNew, flags: fileFlagOpenReparsePoint))
    #else
    let fd = openIn(AT_FDCWD, Array(path.utf8), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
    if fd < 0 {
        throw systemFailure(errno)
    }
    return DiskFile(fd: fd)
    #endif
}

/// Whether anything is at `path`, as the caller names it, a link too. The last
/// name is not followed.
func existsAt(_ path: String) -> Bool {
    #if os(Windows)
    guard let exact = try? exactPath(path) else {
        return false
    }
    var data = WIN32_FILE_ATTRIBUTE_DATA()
    return GetFileAttributesExW(exact + [0], GetFileExInfoStandard, &data)
    #else
    var info = stat()
    return path.withCString { lstat($0, &info) } == 0
    #endif
}

/// Whether the thing at `path`, as the caller names it, is a folder.
func isFolderAt(_ path: String) throws -> Bool {
    #if os(Windows)
    var data = WIN32_FILE_ATTRIBUTE_DATA()
    if !GetFileAttributesExW(try exactPath(path) + [0], GetFileExInfoStandard, &data) {
        throw systemFailure(GetLastError())
    }
    return data.dwFileAttributes & fileAttributeDirectory != 0
    #else
    var info = stat()
    let status = path.withCString { stat($0, &info) }
    if status != 0 {
        throw systemFailure(errno)
    }
    return found(mode: UInt32(info.st_mode)) == .folder
    #endif
}
