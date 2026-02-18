// Serialization.swift — JSON and CBOR serialization/deserialization
//
// Ported from dag/serialize.go.
// Uses Swift Codable for JSON, CBOREncoder/CBORDecoder for CBOR.
// FromSerializable rebuilds Classic Merkle Trees from links and reconstructs parent hashes.
//
// CBOR field names match Go's fxamacker/cbor defaults:
//   - PascalCase for all fields (Hash, ItemName, Type, etc.)
//   - Except StoredProofs which has cbor:"stored_proofs" tag

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

// MARK: - CBOR Serialization

extension Dag {

    /// Serializes the DAG to CBOR format.
    ///
    /// Mirrors Go's `ToCBOR()`. Uses PascalCase field names matching fxamacker/cbor defaults.
    public func toCBOR() -> Data {
        let cborEncoder = CBOREncoder()
        let serializable = toSerializable()

        var leafPairs: [(String, CBORValue)] = []
        for (hash, sLeaf) in serializable.leafs {
            leafPairs.append((hash, serializableDagLeafToCBOR(sLeaf)))
        }

        return cborEncoder.encodeMap([
            ("Root", .textString(serializable.root)),
            ("Leafs", .map(CBOROrderedMap(leafPairs))),
        ])
    }

    /// Deserializes a DAG from CBOR format.
    ///
    /// Mirrors Go's `FromCBOR(data)`.
    public static func fromCBOR(_ data: Data) throws -> Dag {
        let decoder = CBORDecoder()
        let value = try decoder.decode(data)

        guard let map = value.mapValue else {
            throw DagError.brokenDag("CBOR root is not a map")
        }

        let root = map["Root"]?.stringValue ?? ""

        var sLeafs: [String: SerializableDagLeaf] = [:]
        if let leafsMap = map["Leafs"]?.mapValue {
            for pair in leafsMap.pairs {
                sLeafs[pair.key] = cborToSerializableDagLeaf(pair.value)
            }
        }

        return fromSerializable(SerializableDag(root: root, leafs: sLeafs))
    }

    /// Reads a DAG from a CBOR file on disk.
    ///
    /// Mirrors Go's `ReadDag(path)`.
    public static func readDag(path: String) throws -> Dag {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        return try fromCBOR(fileData)
    }
}

// MARK: - CBOR Encoding Helpers

func serializableDagLeafToCBOR(_ sLeaf: SerializableDagLeaf) -> CBORValue {
    var pairs: [(String, CBORValue)] = [
        ("Hash", .textString(sLeaf.hash)),
        ("ItemName", .textString(sLeaf.itemName)),
        ("Type", .textString(sLeaf.type)),
        ("ContentHash", .optionalBytes(sLeaf.contentHash)),
        ("Content", .optionalBytes(sLeaf.content)),
        ("ClassicMerkleRoot", .optionalBytes(sLeaf.classicMerkleRoot)),
        ("CurrentLinkCount", .int(sLeaf.currentLinkCount)),
        ("LeafCount", .int(sLeaf.leafCount)),
        ("ContentSize", .int64(sLeaf.contentSize)),
        ("DagSize", .int64(sLeaf.dagSize)),
        ("Links", sLeaf.links.isEmpty ? .null : .array(sLeaf.links.map { .textString($0) })),
        ("AdditionalData", encodeSortedMapToCBOR(sLeaf.additionalData)),
    ]

    if let sp = sLeaf.storedProofs, !sp.isEmpty {
        var proofPairs: [(String, CBORValue)] = []
        for (k, v) in sp {
            proofPairs.append((k, serializableProofToCBOR(v)))
        }
        pairs.append(("stored_proofs", .map(CBOROrderedMap(proofPairs))))
    }

    return .map(CBOROrderedMap(pairs))
}

func serializableProofToCBOR(_ sp: SerializableProof) -> CBORValue {
    return .map(CBOROrderedMap([
        ("Leaf", .textString(sp.leaf)),
        ("Proof", .map(CBOROrderedMap([
            ("Siblings", .array(sp.siblings.map { .byteString($0) })),
            ("Path", .unsignedInt(UInt64(sp.path))),
        ]))),
    ]))
}

func encodeSortedMapToCBOR(_ m: [String: String]) -> CBORValue {
    if m.isEmpty {
        return .map(CBOROrderedMap([]))
    }
    let sorted = m.sorted { $0.key < $1.key }
    return .map(CBOROrderedMap(sorted.map { ($0.key, CBORValue.textString($0.value)) }))
}

// MARK: - CBOR Decoding Helpers

func cborToSerializableDagLeaf(_ value: CBORValue) -> SerializableDagLeaf {
    guard let map = value.mapValue else { return SerializableDagLeaf() }

    var sLeaf = SerializableDagLeaf()
    sLeaf.hash = map["Hash"]?.stringValue ?? ""
    sLeaf.itemName = map["ItemName"]?.stringValue ?? ""
    sLeaf.type = map["Type"]?.stringValue ?? "file"
    sLeaf.contentHash = map["ContentHash"]?.dataValue
    sLeaf.content = map["Content"]?.dataValue
    sLeaf.classicMerkleRoot = map["ClassicMerkleRoot"]?.dataValue
    sLeaf.currentLinkCount = map["CurrentLinkCount"]?.intValue ?? 0
    sLeaf.leafCount = map["LeafCount"]?.intValue ?? 0
    sLeaf.contentSize = map["ContentSize"]?.int64Value ?? 0
    sLeaf.dagSize = map["DagSize"]?.int64Value ?? 0

    if let linksArray = map["Links"]?.arrayValue {
        sLeaf.links = linksArray.compactMap { $0.stringValue }
    }

    if let adMap = map["AdditionalData"]?.mapValue {
        for pair in adMap.pairs {
            if let val = pair.value.stringValue {
                sLeaf.additionalData[pair.key] = val
            }
        }
    }

    if let proofsMap = map["stored_proofs"]?.mapValue {
        var sp: [String: SerializableProof] = [:]
        for pair in proofsMap.pairs {
            sp[pair.key] = cborToSerializableProof(pair.value)
        }
        sLeaf.storedProofs = sp
    }

    return sLeaf
}

func cborToSerializableProof(_ value: CBORValue) -> SerializableProof {
    guard let map = value.mapValue else { return SerializableProof() }

    var sp = SerializableProof()
    sp.leaf = map["Leaf"]?.stringValue ?? ""

    if let proofMap = map["Proof"]?.mapValue {
        if let siblingsArray = proofMap["Siblings"]?.arrayValue {
            sp.siblings = siblingsArray.compactMap { $0.dataValue }
        }
        sp.path = UInt32(proofMap["Path"]?.uintValue ?? 0)
    }

    return sp
}
