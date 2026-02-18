// Serialization.swift — JSON serialization/deserialization
//
// Ported from dag/serialize.go.
// Uses Swift Codable for JSON round-trips through SerializableDag intermediate.
// FromSerializable rebuilds Classic Merkle Trees from links and reconstructs parent hashes.

import Foundation

// MARK: - Serializable Types (Codable)

public struct SerializableDagLeaf: Codable {
    public var hash: String = ""
    public var itemName: String = ""
    public var type: String = ""
    public var contentHash: Data? = nil
    public var content: Data? = nil
    public var classicMerkleRoot: Data? = nil
    public var currentLinkCount: Int = 0
    public var leafCount: Int = 0
    public var contentSize: Int64 = 0
    public var dagSize: Int64 = 0
    public var links: [String] = []
    public var additionalData: [String: String] = [:]
    public var storedProofs: [String: SerializableProof]? = nil

    enum CodingKeys: String, CodingKey {
        case hash, itemName, type, contentHash, content, classicMerkleRoot
        case currentLinkCount, leafCount, contentSize, dagSize
        case links, additionalData
        case storedProofs = "stored_proofs"
    }
}

public struct SerializableProof: Codable {
    public var leaf: String = ""
    public var siblings: [Data] = []
    public var path: UInt32 = 0
}

public struct SerializableDag: Codable {
    public var root: String = ""
    public var leafs: [String: SerializableDagLeaf] = [:]
}

// MARK: - Dag → JSON

extension Dag {

    /// Converts the DAG to its serializable intermediate form.
    public func toSerializable() -> SerializableDag {
        var serializable = SerializableDag(root: root)

        for (hash, leaf) in leafs {
            var sLeaf = SerializableDagLeaf()
            sLeaf.hash = leaf.hash
            sLeaf.itemName = leaf.itemName
            sLeaf.type = leaf.type.rawValue
            sLeaf.contentHash = leaf.contentHash
            sLeaf.content = leaf.content
            sLeaf.classicMerkleRoot = leaf.classicMerkleRoot.isEmpty ? nil : leaf.classicMerkleRoot
            sLeaf.currentLinkCount = leaf.currentLinkCount
            sLeaf.leafCount = leaf.leafCount
            sLeaf.contentSize = leaf.contentSize
            sLeaf.dagSize = leaf.dagSize
            sLeaf.links = leaf.links
            sLeaf.additionalData = sortMapByKeys(leaf.additionalData)

            // Convert proofs
            if !leaf.proofs.isEmpty {
                var sp: [String: SerializableProof] = [:]
                for (k, v) in leaf.proofs {
                    sp[k] = SerializableProof(leaf: v.leaf, siblings: v.proof.siblings, path: v.proof.path)
                }
                sLeaf.storedProofs = sp
            }

            serializable.leafs[hash] = sLeaf
        }

        return serializable
    }

    /// Serializes the DAG to JSON.
    public func toJSON() throws -> Data {
        let serializable = toSerializable()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(serializable)
    }

    /// Deserializes a DAG from JSON.
    public static func fromJSON(_ data: Data) throws -> Dag {
        let decoder = JSONDecoder()
        let serializable = try decoder.decode(SerializableDag.self, from: data)
        return fromSerializable(serializable)
    }

    /// Reconstructs a Dag from its serializable form.
    ///
    /// Rebuilds Classic Merkle Trees from links and reconstructs parent hashes.
    public static func fromSerializable(_ s: SerializableDag) -> Dag {
        let dag = Dag(root: s.root)

        // First pass: create all leaves
        for (hash, sLeaf) in s.leafs {
            let leaf = DagLeaf()
            leaf.hash = sLeaf.hash
            leaf.itemName = sLeaf.itemName
            leaf.type = LeafType(rawValue: sLeaf.type) ?? .file
            leaf.contentHash = sLeaf.contentHash
            leaf.content = sLeaf.content
            leaf.classicMerkleRoot = sLeaf.classicMerkleRoot ?? Data()
            leaf.currentLinkCount = sLeaf.currentLinkCount
            leaf.links = sLeaf.links
            leaf.additionalData = sortMapByKeys(sLeaf.additionalData)

            // Root-specific fields
            if hash == s.root {
                leaf.leafCount = sLeaf.leafCount
                leaf.contentSize = sLeaf.contentSize
                leaf.dagSize = sLeaf.dagSize
            }

            // Restore proofs
            if let sp = sLeaf.storedProofs {
                for (k, v) in sp {
                    leaf.proofs[k] = ClassicTreeBranch(
                        leaf: v.leaf,
                        proof: Proof(siblings: v.siblings, path: v.path)
                    )
                }
            }

            dag.leafs[hash] = leaf
        }

        // Check if partial
        var isPartialDag = false
        for (_, leaf) in dag.leafs {
            if leaf.links.count < leaf.currentLinkCount {
                isPartialDag = true
                break
            }
        }

        // For full DAGs, rebuild Classic Merkle Trees
        if !isPartialDag {
            for (_, leaf) in dag.leafs {
                if leaf.links.count > 1 {
                    let builder = TreeContent()
                    for link in leaf.links {
                        builder.addLeaf(key: link, data: link)
                    }
                    if let (merkleTree, leafMap) = try? builder.build() {
                        leaf.merkleTree = merkleTree
                        leaf.leafMap = leafMap
                        leaf.classicMerkleRoot = merkleTree.root
                    }
                }
            }
        }

        // Third pass: reconstruct parent hashes
        for (hash, leaf) in dag.leafs {
            for (_, potential) in dag.leafs {
                if potential.hasLink(hash) {
                    leaf.parentHash = potential.hash
                    break
                }
            }
        }

        return dag
    }
}
