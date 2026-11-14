import Foundation
import XCTest
@testable import ScionicMerkleTree

/// A failure that a helper of the tests found.
struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The package's folder, found from where this file is: `tests/Support/`.
let packageFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The bytes of a file of the package, by its path from the package's folder.
func packageFile(_ path: String) throws -> [UInt8] {
    var url = packageFolder
    for name in path.split(separator: "/") {
        url.appendPathComponent(String(name))
    }
    return [UInt8](try Data(contentsOf: url))
}

/// The bytes of `text`, which is lower-case hex.
func hexBytes(_ text: String) throws -> [UInt8] {
    let digits = Array(text.utf8)
    guard digits.count % 2 == 0 else {
        throw TestFailure("\(text.prefix(40)) is not hex")
    }
    func value(_ digit: UInt8) throws -> UInt8 {
        switch digit {
        case 0x30...0x39:
            return digit - 0x30
        case 0x61...0x66:
            return digit - 0x61 + 10
        default:
            throw TestFailure("\(text.prefix(40)) is not lower-case hex")
        }
    }
    var out: [UInt8] = []
    out.reserveCapacity(digits.count / 2)
    var at = 0
    while at < digits.count {
        out.append(try value(digits[at]) << 4 | value(digits[at + 1]))
        at += 2
    }
    return out
}

/// `bytes` as lower-case hex.
func hexText<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 15)])
    }
    return String(decoding: out, as: UTF8.self)
}

/// What a manifest's objects may hold: for each kind of object, the names of
/// its members.
indirect enum Shape: Sendable {
    /// A string, a number, true, false or null.
    case value
    /// An object with these members, of which those in `optional` may be left out.
    case object([String: Shape], optional: Set<String> = [])
    /// An object whose members' names are free, each of this shape.
    case map(Shape)
    case array(Shape)
    /// The shape that `named` stands for, for shapes that hold themselves.
    case named(String)
}

/// Holds `value` to `shape`: every member of every object has to be one that
/// the tests know, and every member that is due has to be there. So nothing in
/// a manifest goes unchecked.
func checkShape(_ value: Any, _ shape: Shape, _ names: [String: Shape], at path: String = "") throws {
    switch shape {
    case .value:
        guard !(value is [String: Any]), !(value is [Any]) else {
            throw TestFailure("\(path) is not a string, a number, true, false or null")
        }
    case let .object(members, optional):
        guard let object = value as? [String: Any] else {
            throw TestFailure("\(path) is not an object")
        }
        for (name, member) in object {
            guard let shape = members[name] else {
                throw TestFailure("\(path) has the member \"\(name)\", which these tests do not know")
            }
            try checkShape(member, shape, names, at: path + "." + name)
        }
        for name in members.keys where object[name] == nil && !optional.contains(name) {
            throw TestFailure("\(path) has no member \"\(name)\"")
        }
    case let .map(shape):
        guard let object = value as? [String: Any] else {
            throw TestFailure("\(path) is not an object")
        }
        for (name, member) in object {
            try checkShape(member, shape, names, at: path + "." + name)
        }
    case let .array(shape):
        guard let items = value as? [Any] else {
            throw TestFailure("\(path) is not an array")
        }
        for (place, item) in items.enumerated() {
            try checkShape(item, shape, names, at: path + "[\(place)]")
        }
    case let .named(name):
        guard let shape = names[name] else {
            throw TestFailure("no shape is named \(name)")
        }
        try checkShape(value, shape, names, at: path)
    }
}

/// Reads one of the manifests under `spec/`, after holding its bytes to the
/// SHA-256 that this library was written against. A manifest that changes has
/// to be changed here too, on purpose.
///
/// The manifest is read with Foundation's JSON reader, and not with code of the
/// library that is under test. It is held to `shape` first, so that a member
/// these tests do not know is an error.
func readManifest<Manifest: Decodable>(
    _ type: Manifest.Type,
    _ path: String,
    sha256: String,
    shape: Shape,
    names: [String: Shape] = [:]
) throws -> Manifest {
    let bytes = try packageFile("spec/" + path)
    let got = Hash.of(bytes).hex
    guard got == sha256 else {
        throw TestFailure("spec/\(path) has the SHA-256 \(got), and these tests were written against \(sha256)")
    }
    let data = Data(bytes)
    try checkShape(try JSONSerialization.jsonObject(with: data), shape, names, at: path)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Manifest.self, from: data)
}
