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
        //
        // This literal is *why* the constant sat at "2.0.0" through the v2.1, v2.2,
        // v2.3 and v2.4 tags: the test pinned the drift instead of catching it, so
        // the only thing guarding the version agreed with the bug. Bump it in the
        // same commit as the tag.
        XCTAssertEqual(ScionicMerkleTree.version, "2.4.2")
    }
}