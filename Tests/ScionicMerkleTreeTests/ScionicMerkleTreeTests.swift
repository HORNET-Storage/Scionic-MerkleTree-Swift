// ScionicMerkleTreeTests.swift — Test suite for the Swift Scionic Merkle Tree port
//
// Test files will mirror the Go test suite:
//   - CBORTests.swift          — CBOR encoding determinism
//   - CIDTests.swift           — CID generation + round-trip
//   - MerkleTreeTests.swift    — Classic Merkle Tree build/verify/proof
//   - DagTests.swift           — DAG creation, verify, directory recreation
//   - SerializationTests.swift — CBOR + JSON round-trip
//   - TransmissionTests.swift  — LeafSync packets
//   - PartialTests.swift       — Partial DAG extraction + verification
//   - DiffTests.swift          — DAG diffing + patching
//   - ParallelTests.swift      — Parallel creation matches sequential
//   - CrossCompatTests.swift   — Go CBOR/JSON -> Swift import (hash compat)
//
// TODO: Implement in Task #14

import XCTest
@testable import ScionicMerkleTree

final class ScionicMerkleTreeTests: XCTestCase {
    func testLibraryVersion() {
        XCTAssertEqual(version, "2.0.0")
    }
}