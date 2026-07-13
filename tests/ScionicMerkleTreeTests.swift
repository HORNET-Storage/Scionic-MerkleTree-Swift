// ScionicMerkleTreeTests.swift — Smoke tests for the Swift Scionic Merkle Tree port
//
// The full suite lives in focused files covering CBOR/CID primitives, Classic Merkle
// Trees, TreeContent wrappers, DAG fixtures, transmission, diff/partial flows,
// and Go cross-compatibility vectors.

import XCTest
@testable import ScionicMerkleTree

final class ScionicMerkleTreeTests: XCTestCase {
    func testLibraryVersion() {
        // Module-qualified: inside an XCTestCase (an NSObject subclass), the bare
        // name `version` resolves to the inherited `NSObject.version()` class method,
        // shadowing the library's top-level constant.
        XCTAssertEqual(ScionicMerkleTree.version, "2.0.0")
    }
}