import XCTest
@testable import ScionicMerkleTree

extension ScionicError {
    /// The name of the case, for the tests that tell errors apart.
    var caseName: String {
        switch self {
        case .io: return "io"
        case .stream: return "stream"
        case .invalidData: return "invalidData"
        case .invalidBase32: return "invalidBase32"
        case .invalidHex: return "invalidHex"
        case .invalidRoot: return "invalidRoot"
        case .invalidName: return "invalidName"
        case .hashMismatch: return "hashMismatch"
        case .sizeMismatch: return "sizeMismatch"
        case .totalsMismatch: return "totalsMismatch"
        case .intakeFailed: return "intakeFailed"
        case .notWanted: return "notWanted"
        case .corrupt: return "corrupt"
        case .missing: return "missing"
        case .tooDeep: return "tooDeep"
        case .unwritableName: return "unwritableName"
        case .unsupportedEntry: return "unsupportedEntry"
        case .nonUTF8FileName: return "nonUTF8FileName"
        case .peer: return "peer"
        case .limitExceeded: return "limitExceeded"
        case .allocationFailed: return "allocationFailed"
        case .sizeOverflow: return "sizeOverflow"
        case .invariant: return "invariant"
        }
    }
}

/// Holds that `body` throws an error of this library, of the case named
/// `named`, or of any case when it is nil. Gives the error.
@discardableResult
func assertFails<T>(
    _ body: @autoclosure () throws -> T,
    _ named: String? = nil,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> ScionicError? {
    do {
        _ = try body()
        XCTFail("no error: \(message())", file: file, line: line)
    } catch let error as ScionicError {
        if let named {
            XCTAssertEqual(error.caseName, named, "\(error) \(message())", file: file, line: line)
        }
        return error
    } catch {
        XCTFail("not an error of the library: \(error) \(message())", file: file, line: line)
    }
    return nil
}

/// Whether `body` gives an answer rather than an error, be the answer nil.
func passes<T>(_ body: () throws -> T) -> Bool {
    do {
        _ = try body()
        return true
    } catch {
        return false
    }
}

extension Result {
    /// The value, or nil when the result is a failure. Unlike `try?`, it keeps a
    /// value that is itself nil apart from a failure.
    var ok: Success? {
        if case let .success(value) = self {
            return value
        }
        return nil
    }
}
