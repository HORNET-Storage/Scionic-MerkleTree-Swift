/// Why something the system was asked to do failed: a number the system gave,
/// what that number means, and what kind of failure it is.
public struct SystemFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The kinds of failure that callers tell apart.
    public enum Kind: Sendable, Equatable {
        case notFound
        case alreadyExists
        case permissionDenied
        /// A link, or something that is neither a file nor a folder, where a
        /// file or a folder was opened.
        case notAPlainFile
        case other
    }

    public let kind: Kind
    /// `errno` on Unix, and the system error code on Windows.
    public let code: Int32
    public let message: String

    public init(kind: Kind, code: Int32, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// Every error of the library.
public enum ScionicError: Error, Sendable, CustomStringConvertible {
    /// The file system refused something.
    case io(operation: String, path: String, failure: SystemFailure)
    /// Reading from a stream or writing to one failed. `failure` is what the
    /// stream gave.
    case stream(operation: String, failure: any Error)
    /// Bytes that are not a well-formed thing of the format.
    case invalidData(String)
    case invalidBase32
    case invalidHex
    /// Text that is not a root.
    case invalidRoot(String)
    /// A name that the format does not allow.
    case invalidName(name: String, reason: String)
    /// A thing does not hash to what it has to.
    case hashMismatch(what: String)
    /// A thing does not have the size it has to.
    case sizeMismatch(what: String, expected: UInt64, actual: UInt64)
    /// A record's totals are not those of its tree.
    case totalsMismatch(field: String, recorded: UInt64, counted: UInt64)
    /// An intake was used again after a part of its tree was refused.
    case intakeFailed
    /// Something arrived that is not tied to the root, or was not asked for.
    case notWanted(what: String)
    /// A store holds, under a hash, bytes that are not what the hash says.
    /// Removing them from the store and fetching the tree again mends it.
    case corrupt(what: String, hash: Hash)
    /// A store does not hold something that the tree needs.
    case missing(what: String, hash: Hash)
    /// Folders sit inside one another more deeply than the format allows.
    case tooDeep(limit: Int)
    /// A name that this system cannot hold as it is.
    case unwritableName(name: String, reason: String)
    /// A link or a special file, where only files and folders are stored.
    case unsupportedEntry(path: String, what: String)
    case nonUTF8FileName(path: String)
    /// A peer could not answer, or stopped early.
    case peer(String)
    case limitExceeded(what: String, limit: UInt64, requested: UInt64)
    case allocationFailed(resource: String, requested: UInt64)
    case sizeOverflow(field: String)
    case invariant(String)

    public var description: String {
        switch self {
        case let .io(operation, path, failure):
            return "failed to \(operation) \(path): \(failure.message)"
        case let .stream(operation, failure):
            return "failed to \(operation): \(failure)"
        case let .invalidData(detail):
            return "malformed: \(detail)"
        case .invalidBase32:
            return "not lowercase base32"
        case .invalidHex:
            return "not lowercase hex of the right length"
        case let .invalidRoot(value):
            return "not a root: \(quoted(value))"
        case let .invalidName(name, reason):
            return "the name \(quoted(name)) is not allowed: \(reason)"
        case let .hashMismatch(what):
            return "\(what) does not hash to what it has to"
        case let .sizeMismatch(what, expected, actual):
            return "\(what) holds \(actual) bytes where \(expected) are due"
        case let .totalsMismatch(field, recorded, counted):
            return "the record says \(recorded) for \(field), and the tree has \(counted)"
        case .intakeFailed:
            return "an intake is done once a part of its tree was refused: start a new one"
        case let .notWanted(what):
            return "\(what) is not tied to the root, or was not asked for"
        case let .corrupt(what, hash):
            return "\(what) \(hash) is damaged: its bytes are not what its hash says"
        case let .missing(what, hash):
            return "\(what) \(hash) is not held"
        case let .tooDeep(limit):
            return "folders sit inside one another more than \(limit) deep"
        case let .unwritableName(name, reason):
            return "the name \(quoted(name)) cannot be written on this system: \(reason)"
        case let .unsupportedEntry(path, what):
            return "\(path) is \(what), and only files and folders are stored"
        case let .nonUTF8FileName(path):
            return "path has a non-UTF-8 file name: \(path)"
        case let .peer(detail):
            return "the peer \(detail)"
        case let .limitExceeded(what, limit, requested):
            return "\(what) needs \(requested), over the limit of \(limit)"
        case let .allocationFailed(resource, requested):
            return "failed to allocate \(requested) bytes for \(resource)"
        case let .sizeOverflow(field):
            return "\(field) exceeds the supported size"
        case let .invariant(detail):
            return "internal invariant failed: \(detail)"
        }
    }
}

/// Text as it is shown inside an error: in quotes, and no longer than 80
/// characters, so that an error never carries a whole input.
func quoted(_ text: String) -> String {
    "\"" + String(text.prefix(80)) + "\""
}

func invalid(_ detail: String) -> ScionicError {
    .invalidData(detail)
}

/// What a stream gave when it failed, as an error of this library. An error of
/// this library stays as it is.
func streamFailure(_ error: any Error, _ operation: String) -> any Error {
    error is ScionicError ? error : ScionicError.stream(operation: operation, failure: error)
}
