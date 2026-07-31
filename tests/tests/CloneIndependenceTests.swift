import Foundation
import XCTest
@testable import ScionicMerkleTree

/// Locks in the rule that a copy handed to a caller can never damage the thing
/// it was copied from.
///
/// `DagLeaf` is a class, so every accessor that returns one is a potential
/// aliasing hazard: the caller gets a live reference and any `leaf.field = x`
/// writes straight back into whatever owns it. Swift's `clone()` is safe for
/// free because every field it copies is a value type -- but that safety is a
/// property of the field list, not of the language, and adding one class-typed
/// field would silently break it. These tests fail if that ever happens.
///
/// The Go port has the same tests in tests/clone_independence_test.go. The one
/// deliberate divergence is content: Go shares the `Content` backing array and
/// documents it, Swift copies it for free via copy-on-write. That divergence is
/// pinned explicitly below so it stays a decision rather than an accident.
final class CloneIndependenceTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a DAG with nested directories, so parents carry more than one
    /// link and real Merkle proofs exist to copy.
    private func buildFixture() throws -> Dag {
        let root = try ParityTestHelpers.makeTempDir("clone_independence")
        try ParityTestHelpers.createDeepHierarchy(at: root)
        return try createDag(path: root)
    }

    /// Picks a leaf deterministically. `dag.leafs` is a dictionary and its
    /// iteration order is unspecified, so an arbitrary `.first` would make a
    /// failure reproduce only sometimes.
    private func lowestLeaf(in dag: Dag, where predicate: (DagLeaf) -> Bool) -> DagLeaf? {
        for hash in dag.leafs.keys.sorted() {
            guard let leaf = dag.leafs[hash], predicate(leaf) else { continue }
            return leaf
        }
        return nil
    }

    // MARK: - clone() independence

    func testCloneIsFullyIndependent() throws {
        let dag = try buildFixture()
        let source = try XCTUnwrap(lowestLeaf(in: dag) { $0.hash != dag.root })

        let originalHash = source.hash
        let originalItemName = source.itemName
        let originalType = source.type
        let originalContentHash = source.contentHash
        let originalMerkleRoot = source.classicMerkleRoot
        let originalLinkCount = source.currentLinkCount
        let originalLeafCount = source.leafCount
        let originalContentSize = source.contentSize
        let originalDagSize = source.dagSize
        let originalLinks = source.links
        let originalParentHash = source.parentHash
        let originalAdditionalData = source.additionalData
        let originalProofCount = source.proofs.count

        let copy = source.clone()
        copy.hash = "tampered-hash"
        copy.itemName = "tampered-name"
        copy.type = originalType == .directory ? .file : .directory
        copy.contentHash = Data(repeating: 0x01, count: 32)
        copy.classicMerkleRoot = Data(repeating: 0x02, count: 32)
        copy.currentLinkCount = originalLinkCount + 999
        copy.leafCount = originalLeafCount + 999
        copy.contentSize = originalContentSize + 999
        copy.dagSize = originalDagSize + 999
        copy.links.append("tampered-link")
        copy.parentHash = "tampered-parent"
        copy.additionalData["tampered"] = "yes"
        copy.proofs["tampered"] = ClassicTreeBranch(
            leaf: "tampered-leaf",
            proof: Proof(siblings: [Data(repeating: 0xFF, count: 32)], path: 7)
        )

        XCTAssertEqual(source.hash, originalHash)
        XCTAssertEqual(source.itemName, originalItemName)
        XCTAssertEqual(source.type, originalType)
        XCTAssertEqual(source.contentHash, originalContentHash)
        XCTAssertEqual(source.classicMerkleRoot, originalMerkleRoot)
        XCTAssertEqual(source.currentLinkCount, originalLinkCount)
        XCTAssertEqual(source.leafCount, originalLeafCount)
        XCTAssertEqual(source.contentSize, originalContentSize)
        XCTAssertEqual(source.dagSize, originalDagSize)
        XCTAssertEqual(source.links, originalLinks)
        XCTAssertEqual(source.parentHash, originalParentHash)
        XCTAssertEqual(source.additionalData, originalAdditionalData)
        XCTAssertEqual(source.proofs.count, originalProofCount)
    }

    /// The precise operation that corrupts the source in Go: writing *through*
    /// a copied buffer rather than reassigning it. Go shares the backing array,
    /// so `clone.ClassicMerkleRoot[0] ^= 0xFF` rewrites the original's bytes.
    /// Swift's `Data` is copy-on-write, so the same write allocates instead.
    func testWritingThroughAClonedBufferDoesNotReachTheSource() throws {
        let dag = try buildFixture()
        let source = try XCTUnwrap(lowestLeaf(in: dag) { !$0.classicMerkleRoot.isEmpty })
        let originalMerkleRoot = source.classicMerkleRoot

        let copy = source.clone()
        copy.classicMerkleRoot[copy.classicMerkleRoot.startIndex] ^= 0xFF

        XCTAssertNotEqual(
            copy.classicMerkleRoot, originalMerkleRoot,
            "the write must actually land on the copy, otherwise this test proves nothing"
        )
        XCTAssertEqual(
            source.classicMerkleRoot, originalMerkleRoot,
            "writing through a cloned classicMerkleRoot must not reach the source leaf"
        )
    }

    /// Pins the deliberate divergence from Go. Go's Clone() shares Content and
    /// documents that callers must reassign rather than write through it; Swift
    /// gets a genuinely independent copy for free. If Swift ever starts sharing
    /// content deliberately, update this test and Types.swift's clone() comment.
    func testContentIsIndependentUnlikeGo() throws {
        let dag = try buildFixture()
        let source = try XCTUnwrap(lowestLeaf(in: dag) { ($0.content?.isEmpty == false) })
        let originalContent = try XCTUnwrap(source.content)

        let copy = source.clone()
        copy.content![copy.content!.startIndex] ^= 0xFF

        XCTAssertNotEqual(copy.content, originalContent, "the write must land on the copy")
        XCTAssertEqual(
            source.content, originalContent,
            "Swift copies content by value; if this now shares, Types.swift's clone() " +
            "doc comment and the cross-language parity note both need updating"
        )
    }

    func testProofBranchesAreIndependent() throws {
        let dag = try buildFixture()
        let targetHash = try XCTUnwrap(lowestLeaf(in: dag) { $0.hash != dag.root }).hash
        let partial = try dag.getPartial(leafHashes: [targetHash], pruneLinks: false)

        let source = try XCTUnwrap(
            lowestLeaf(in: partial) { !$0.proofs.isEmpty },
            "fixture must produce at least one leaf carrying proofs, otherwise this test is vacuous"
        )
        let proofKey = try XCTUnwrap(source.proofs.keys.sorted().first)
        let originalBranch = try XCTUnwrap(source.proofs[proofKey])
        let originalSiblings = originalBranch.proof.siblings
        let originalPath = originalBranch.proof.path
        let originalLeaf = originalBranch.leaf

        let copy = source.clone()
        copy.proofs[proofKey]!.leaf = "tampered-leaf"
        copy.proofs[proofKey]!.proof.path = originalPath ^ 0xFFFF
        copy.proofs[proofKey]!.proof.siblings = [Data(repeating: 0xAB, count: 32)]

        let after = try XCTUnwrap(source.proofs[proofKey])
        XCTAssertEqual(after.leaf, originalLeaf)
        XCTAssertEqual(after.proof.path, originalPath)
        XCTAssertEqual(after.proof.siblings, originalSiblings)
    }

    // MARK: - DAG level

    func testTamperingACloneNeverDamagesTheSourceDag() throws {
        let dag = try buildFixture()
        try dag.verify()

        // The decisive check: a fresh, UNtampered clone of the source must still
        // verify. If it does not, the source was already damaged and the assertion
        // below would hold without this test doing anything.
        try ParityTestHelpers.clonedDag(dag).verify()

        let tampered = ParityTestHelpers.clonedDag(dag)
        let victim = try XCTUnwrap(tampered.leafs[tampered.root])
        victim.classicMerkleRoot[victim.classicMerkleRoot.startIndex] ^= 0xFF
        if victim.content?.isEmpty == false {
            victim.content![victim.content!.startIndex] ^= 0xFF
        }

        XCTAssertThrowsError(try tampered.verify(), "the tampered clone must fail verification")
        XCTAssertNoThrow(try dag.verify(), "tampering a clone must leave the source DAG intact")
    }

    /// Creating a partial DAG mutates the partial's leaves -- it merges proofs in
    /// and, when pruneLinks is set, rewrites their link lists. Those leaves must
    /// be clones, or building a partial would silently strip links off the DAG it
    /// was derived from.
    func testBuildingAPartialDoesNotDamageTheSourceDag() throws {
        let dag = try buildFixture()
        let rootLeaf = try XCTUnwrap(dag.leafs[dag.root])
        let originalRootLinks = rootLeaf.links
        let originalLeafCount = dag.leafs.count
        let target = try XCTUnwrap(originalRootLinks.sorted().first)

        let partial = try dag.getPartial(leafHashes: [target], pruneLinks: true)
        try partial.verify()

        XCTAssertEqual(
            rootLeaf.links, originalRootLinks,
            "pruneIrrelevantLinks must prune the partial's leaves, not the source's"
        )
        XCTAssertEqual(dag.leafs.count, originalLeafCount)
        XCTAssertNoThrow(try dag.verify(), "taking a partial must leave the source DAG verifiable")
    }

    // MARK: - Store level

    /// Every read on MemoryLeafStore hands back a copy the caller owns. This
    /// pins the accessor that used to be the exception: getAllLeaves() returned
    /// the stored instances themselves, so a caller could rewrite the store's
    /// contents in place -- outside the lock, and outside the content-preserving
    /// merge in storeLeafUnlocked.
    func testStoreReadsReturnOwnedCopies() throws {
        let dag = try buildFixture()
        let store = MemoryLeafStore()
        // Hand the store its own instances, so the only route back to them is a
        // store accessor. Otherwise the test would be probing its own references.
        for hash in dag.leafs.keys.sorted() {
            try store.storeLeaf(dag.leafs[hash]!.clone())
        }

        let targetHash = try XCTUnwrap(dag.leafs.keys.sorted().first)
        let before = try XCTUnwrap(try store.retrieveLeaf(targetHash))
        let originalMerkleRoot = before.classicMerkleRoot
        let originalLinks = before.links
        let originalContent = before.content

        for handedOut in [
            store.getAllLeaves()[targetHash],
            try store.retrieveLeaf(targetHash),
            try store.retrieveLeafWithoutContent(targetHash),
            try store.retrieveLeaves([targetHash])[targetHash],
        ] {
            let leaf = try XCTUnwrap(handedOut)
            leaf.classicMerkleRoot = Data(repeating: 0xFF, count: 32)
            leaf.links = ["tampered-link"]
            leaf.content = Data("tampered".utf8)
        }

        let after = try XCTUnwrap(try store.retrieveLeaf(targetHash))
        XCTAssertEqual(
            after.classicMerkleRoot, originalMerkleRoot,
            "mutating a leaf handed out by the store must not rewrite the stored leaf"
        )
        XCTAssertEqual(after.links, originalLinks)
        XCTAssertEqual(after.content, originalContent)
    }
}
