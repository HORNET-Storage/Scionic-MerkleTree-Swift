// Leaves.swift — Leaf building, hashing, and verification
//
// Ported from dag/leaves.go. The heart of the library — constructs leaves,
// generates CID hashes via CBOR serialization + SHA256, and verifies integrity.
//
// The hashing pipeline:
//   1. Build a struct with leaf fields in exact Go field order
//   2. CBOR-encode the struct (deterministic, matching fxamacker/cbor)
//   3. Generate CIDv1 from CBOR bytes (SHA-256 + codec 0x51)
//   4. Store CID as base32lower string (the leaf's "hash")

import Foundation
import Crypto

// MARK: - DagLeafBuilder Extensions (Build Leaf)

extension DagLeafBuilder {

    /// Builds a non-root DagLeaf from this builder's state.
    ///
    /// Mirrors Go's `BuildLeaf`. The CBOR struct fields are in this exact order:
    ///   ItemName, Type, MerkleRoot, CurrentLinkCount, ContentHash, AdditionalData
    public func buildLeaf(additionalData: [String: String]?) throws -> DagLeaf {
        guard !leafType.rawValue.isEmpty else {
            throw DagError.leafMustHaveType
        }

        // Build Classic Merkle Tree from links
        var merkleRoot = Data()
        var merkleTree: MerkleTree? = nil
        var leafMap: [String: DataBlock]? = nil

        if links.count > 1 {
            let builder = TreeContent()
            for link in links {
                builder.addLeaf(key: link, data: link)
            }
            let (tree, lMap) = try builder.build()
            merkleTree = tree
            leafMap = lMap
            merkleRoot = tree.root
        } else if links.count == 1 {
            // Single link: merkle root is the raw bytes of the link string
            merkleRoot = Data(links[0].utf8)
        }
        // 0 links: merkleRoot stays as empty Data()

        let sortedAdditionalData = sortMapByKeys(additionalData)
        let sortedKV = sortMapForVerification(sortedAdditionalData)

        // Build the CBOR struct matching Go's anonymous struct field order exactly
        let encoder = CBOREncoder()

        var contentHashBytes: Data? = nil
        if let d = data {
            let hash = SHA256.hash(data: d)
            contentHashBytes = Data(hash)
        }

        let additionalDataCBOR: CBORValue
        if let kv = sortedKV {
            additionalDataCBOR = .array(kv.map { $0.toCBOR() })
        } else {
            additionalDataCBOR = .null
        }

        let serialized = encoder.encodeMap([
            ("ItemName", .textString(itemName)),
            ("Type", .textString(leafType.rawValue)),
            ("MerkleRoot", .byteString(merkleRoot)),
            ("CurrentLinkCount", .int(links.count)),
            ("ContentHash", .optionalBytes(contentHashBytes)),
            ("AdditionalData", additionalDataCBOR),
        ])

        // Generate CID
        let cid = CID.generate(from: serialized)

        // Sort links for directories (chunk order must be preserved for files)
        var sortedLinks = links
        if leafType == .directory {
            sortedLinks = links.sorted()
        }

        // Build the leaf
        let leaf = DagLeaf()
        leaf.hash = cid.toString()
        leaf.itemName = itemName
        leaf.type = leafType
        leaf.classicMerkleRoot = merkleRoot
        leaf.currentLinkCount = links.count
        leaf.content = data
        leaf.contentHash = contentHashBytes
        leaf.links = sortedLinks
        leaf.additionalData = sortedAdditionalData
        leaf.merkleTree = merkleTree
        leaf.leafMap = leafMap

        return leaf
    }

    /// Builds a root DagLeaf from this builder's state.
    ///
    /// Mirrors Go's `BuildRootLeaf`. The CBOR struct has additional fields:
    ///   ItemName, Type, MerkleRoot, CurrentLinkCount, LeafCount,
    ///   ContentSize, DagSize, ContentHash, AdditionalData
    public func buildRootLeaf(dag: DagBuilder, additionalData: [String: String]?) throws -> DagLeaf {
        guard !leafType.rawValue.isEmpty else {
            throw DagError.leafMustHaveType
        }

        // Build Classic Merkle Tree from links
        var merkleRoot = Data()
        var merkleTree: MerkleTree? = nil
        var leafMap: [String: DataBlock]? = nil

        if links.count > 1 {
            let builder = TreeContent()
            for link in links {
                builder.addLeaf(key: link, data: link)
            }
            let (tree, lMap) = try builder.build()
            merkleTree = tree
            leafMap = lMap
            merkleRoot = tree.root
        } else if links.count == 1 {
            merkleRoot = Data(links[0].utf8)
        }

        // Calculate content size from all children
        var contentSize: Int64 = 0
        for (_, dagLeaf) in dag.leafs {
            if let content = dagLeaf.content {
                contentSize += Int64(content.count)
            }
        }
        if let d = data {
            contentSize += Int64(d.count)
        }

        // Calculate dag size: serialize each child leaf to CBOR to get their sizes
        let cborEncoder = CBOREncoder()
        var childrenDagSize: Int64 = 0
        for (_, dagLeaf) in dag.leafs {
            let childSerialized = cborEncoder.encodeMap(
                buildLeafSizeStruct(dagLeaf)
            )
            childrenDagSize += Int64(childSerialized.count)
        }

        var contentHashBytes: Data? = nil
        if let d = data {
            let hash = SHA256.hash(data: d)
            contentHashBytes = Data(hash)
        }

        // First pass: serialize temp root to calculate its size (with DagSize=0)
        let tempSerialized = cborEncoder.encodeMap([
            ("ItemName", .textString(itemName)),
            ("Type", .textString(leafType.rawValue)),
            ("MerkleRoot", .byteString(merkleRoot)),
            ("CurrentLinkCount", .int(links.count)),
            ("LeafCount", .int(dag.leafs.count + 1)),
            ("ContentSize", .int64(contentSize)),
            ("DagSize", .int64(0)),
            ("ContentHash", .optionalBytes(contentHashBytes)),
            ("AdditionalData", .null),
        ])
        let rootLeafSize = Int64(tempSerialized.count)
        let finalDagSize = childrenDagSize + rootLeafSize

        let sortedAdditionalData = sortMapByKeys(additionalData)
        let sortedKV = sortMapForVerification(sortedAdditionalData)

        let additionalDataCBOR: CBORValue
        if let kv = sortedKV {
            additionalDataCBOR = .array(kv.map { $0.toCBOR() })
        } else {
            additionalDataCBOR = .null
        }

        // Final serialization with correct DagSize
        let serialized = cborEncoder.encodeMap([
            ("ItemName", .textString(itemName)),
            ("Type", .textString(leafType.rawValue)),
            ("MerkleRoot", .byteString(merkleRoot)),
            ("CurrentLinkCount", .int(links.count)),
            ("LeafCount", .int(dag.leafs.count + 1)),
            ("ContentSize", .int64(contentSize)),
            ("DagSize", .int64(finalDagSize)),
            ("ContentHash", .optionalBytes(contentHashBytes)),
            ("AdditionalData", additionalDataCBOR),
        ])

        // Generate CID
        let cid = CID.generate(from: serialized)

        // Sort links for directories
        var sortedLinks = links
        if leafType == .directory {
            sortedLinks = links.sorted()
        }

        // Build the root leaf
        let leaf = DagLeaf()
        leaf.hash = cid.toString()
        leaf.itemName = itemName
        leaf.type = leafType
        leaf.classicMerkleRoot = merkleRoot
        leaf.currentLinkCount = links.count
        leaf.leafCount = dag.leafs.count + 1
        leaf.contentSize = contentSize
        leaf.dagSize = finalDagSize
        leaf.content = data
        leaf.contentHash = contentHashBytes
        leaf.links = sortedLinks
        leaf.additionalData = sortedAdditionalData
        leaf.merkleTree = merkleTree
        leaf.leafMap = leafMap

        return leaf
    }
}

// MARK: - DagLeaf Verification

extension DagLeaf {

    /// Verifies the leaf's hash by re-computing the CID from its fields.
    ///
    /// Mirrors Go's `VerifyLeaf`. Re-serializes the same CBOR struct and checks the CID matches.
    public func verifyLeaf() throws {
        let sortedAD = sortMapByKeys(additionalData)
        let sortedKV = sortMapForVerification(sortedAD)

        var merkleRootForHash = classicMerkleRoot
        if classicMerkleRoot.isEmpty {
            merkleRootForHash = Data()
        }

        let additionalDataCBOR: CBORValue
        if let kv = sortedKV {
            additionalDataCBOR = .array(kv.map { $0.toCBOR() })
        } else {
            additionalDataCBOR = .null
        }

        let encoder = CBOREncoder()
        let serialized = encoder.encodeMap([
            ("ItemName", .textString(itemName)),
            ("Type", .textString(type.rawValue)),
            ("MerkleRoot", .byteString(merkleRootForHash)),
            ("CurrentLinkCount", .int(currentLinkCount)),
            ("ContentHash", .optionalBytes(contentHash)),
            ("AdditionalData", additionalDataCBOR),
        ])

        let computedCID = CID.generate(from: serialized)
        let storedCID = try CID.decode(hash)

        guard computedCID.equals(storedCID) else {
            throw DagError.leafVerificationFailed
        }
    }

    /// Verifies the root leaf's hash by re-computing the CID.
    ///
    /// Mirrors Go's `VerifyRootLeaf`. Includes LeafCount, ContentSize, DagSize in the hash.
    public func verifyRootLeaf(dag: Dag) throws {
        let sortedAD = sortMapByKeys(additionalData)
        let sortedKV = sortMapForVerification(sortedAD)

        let additionalDataCBOR: CBORValue
        if let kv = sortedKV {
            additionalDataCBOR = .array(kv.map { $0.toCBOR() })
        } else {
            additionalDataCBOR = .null
        }

        let encoder = CBOREncoder()
        let serialized = encoder.encodeMap([
            ("ItemName", .textString(itemName)),
            ("Type", .textString(type.rawValue)),
            ("MerkleRoot", .byteString(classicMerkleRoot)),
            ("CurrentLinkCount", .int(currentLinkCount)),
            ("LeafCount", .int(leafCount)),
            ("ContentSize", .int64(contentSize)),
            ("DagSize", .int64(dagSize)),
            ("ContentHash", .optionalBytes(contentHash)),
            ("AdditionalData", additionalDataCBOR),
        ])

        let computedCID = CID.generate(from: serialized)
        let storedCID = try CID.decode(hash)

        guard computedCID.equals(storedCID) else {
            throw DagError.leafVerificationFailed
        }
    }

    /// Verifies that the Classic Merkle Root matches the actual children.
    public func verifyChildrenAgainstMerkleRoot(dag: Dag) throws {
        guard currentLinkCount > 1 else {
            // Single child: ClassicMerkleRoot = raw bytes of child hash
            if currentLinkCount == 1 && !links.isEmpty {
                let expectedRoot = Data(links[0].utf8)
                guard classicMerkleRoot == expectedRoot else {
                    throw DagError.merkleRootMismatch
                }
            }
            return
        }

        // Rebuild the Classic Merkle Tree from children
        let builder = TreeContent()
        for link in links {
            builder.addLeaf(key: link, data: link)
        }
        let (tree, _) = try builder.build()

        guard tree.root == classicMerkleRoot else {
            throw DagError.merkleRootMismatch
        }
    }

    /// Gets a Classic Merkle Tree branch (proof) for a specific child link.
    public func getBranch(key: String) throws -> ClassicTreeBranch {
        guard let tree = merkleTree else {
            throw DagError.merkleTreeNotBuilt
        }

        let (index, exists) = tree.getIndexForKey(key)
        guard exists else {
            throw DagError.linkNotFound(key)
        }

        let proof = tree.proofs[index]
        return ClassicTreeBranch(leaf: key, proof: proof)
    }

    /// Verifies a Classic Merkle Tree branch against this leaf's Merkle root.
    public func verifyBranch(_ branch: ClassicTreeBranch) throws {
        let leaf = TreeLeaf(branch.leaf)
        try MerkleTree.verify(
            dataBlock: leaf,
            proof: branch.proof,
            root: classicMerkleRoot,
            config: nil
        )
    }
}

// MARK: - Errors

public enum DagError: Error, Equatable {
    case leafMustHaveType
    case leafVerificationFailed
    case merkleRootMismatch
    case merkleTreeNotBuilt
    case linkNotFound(String)
    case invalidLink(String)
    case brokenPathToRoot(String)
    case brokenDag(String)
    case childMissing(String)
}

// MARK: - Internal Helpers

/// Builds the CBOR field pairs for calculating a leaf's serialized size.
/// Used by BuildRootLeaf to compute DagSize.
func buildLeafSizeStruct(_ leaf: DagLeaf) -> [(String, CBORValue)] {
    var linkHashes: [String] = []
    if !leaf.links.isEmpty {
        linkHashes = leaf.links.sorted()
    }

    let linksValue: CBORValue = linkHashes.isEmpty
        ? .null
        : .array(linkHashes.map { .textString($0) })

    let additionalDataValue: CBORValue
    if leaf.additionalData.isEmpty {
        additionalDataValue = .map(CBOROrderedMap([]))
    } else {
        let sorted = leaf.additionalData.sorted { $0.key < $1.key }
        additionalDataValue = .map(CBOROrderedMap(
            sorted.map { ($0.key, CBORValue.textString($0.value)) }
        ))
    }

    return [
        ("Hash", .textString(leaf.hash)),
        ("ItemName", .textString(leaf.itemName)),
        ("Type", .textString(leaf.type.rawValue)),
        ("ContentHash", .optionalBytes(leaf.contentHash)),
        ("Content", .optionalBytes(leaf.content)),
        ("ClassicMerkleRoot", .optionalBytes(
            leaf.classicMerkleRoot.isEmpty ? nil : leaf.classicMerkleRoot
        )),
        ("CurrentLinkCount", .int(leaf.currentLinkCount)),
        ("LeafCount", .int(leaf.leafCount)),
        ("ContentSize", .int64(leaf.contentSize)),
        ("DagSize", .int64(leaf.dagSize)),
        ("Links", linksValue),
        ("AdditionalData", additionalDataValue),
    ]
}
