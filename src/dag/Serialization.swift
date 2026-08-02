// Serialization.swift — JSON and CBOR serialization/deserialization
//
// Ported from dag/serialize.go.
//
// Both wire formats are written from ONE shared tree: `wireValue(order:)` builds a
// `CBORValue`, and either `CBOREncoder` or `encodeWireJSON` writes it out. That is
// what makes key names and struct field order structurally unable to drift between
// CBOR and JSON -- the two writers are reading the same tree, not two parallel
// descriptions of it. Decoding mirrors that: JSON is parsed, walked into the same
// `CBORValue` shape, and handed to the one set of `cborToSerializable*` decoders.
//
// The serializable types are deliberately NOT Codable. Foundation's JSONEncoder
// cannot reproduce Go's output -- it has no declaration-order mode, writes
// `"k" : v`, expands empty containers across three lines, omits nil keys where Go
// writes `null`, and escapes the solidus. A Codable conformance here would be a
// loaded gun: any consumer calling JSONEncoder on these types would silently emit
// JSON that no other port can read. Wire JSON goes through toJSON()/fromJSON().
//
// Field names match Go's fxamacker/cbor and encoding/json defaults:
//   - PascalCase for all fields (Hash, ItemName, Type, etc.)
//   - Except stored_proofs, which Go tags `stored_proofs,omitempty` in both formats

import Foundation

// MARK: - Serializable Types

public struct SerializableDagLeaf {
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
}

public struct SerializableProof {
    public var leaf: String = ""
    public var siblings: [Data] = []
    public var path: UInt32 = 0
}

public struct SerializableDag {
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
            sLeaf.classicMerkleRoot = leaf.classicMerkleRoot
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

    /// Serializes the DAG to JSON, byte-identical to Go's `ToJSON()`.
    ///
    /// The `.json` key order is not cosmetic. Go reaches JSON through
    /// `encoding/json`, which sorts map keys bytewise with no length term, while
    /// CBOR sorts length-first. The two disagree whenever a dynamic map holds keys
    /// of differing length -- in practice, AdditionalData.
    public func toJSON() throws -> Data {
        return try encodeWireJSON(wireValue(order: .json))
    }

    /// Deserializes a DAG from JSON.
    public static func fromJSON(_ data: Data) throws -> Dag {
        return try fromWireValue(jsonDagToCBOR(parseWireJSON(data)))
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

        // Third pass: reconstruct parent hashes via a single child -> parent
        // index. buildParentIndex resolves a content-identical leaf's several
        // parents to the lowest parent hash; the nested scan this replaced kept
        // whichever parent dictionary order yielded first, so a shared chunk's
        // parentHash changed from one deserialization of the same bytes to the
        // next. It is also O(n) rather than O(n^2).
        let parentOf = dag.buildParentIndex()
        for (hash, leaf) in dag.leafs {
            if let parentHash = parentOf[hash] {
                leaf.parentHash = parentHash
            }
        }

        return dag
    }
}

// MARK: - CBOR Serialization

extension Dag {

    /// Builds the wire tree that BOTH output formats are written from.
    ///
    /// Leafs is a genuine dynamic map (Go: SerializableDag.Leafs), so it sorts. The
    /// two pairs around it are struct fields and must stay in declaration order.
    func wireValue(order: WireKeyOrder) -> CBORValue {
        let serializable = toSerializable()

        var leafPairs: [(String, CBORValue)] = []
        leafPairs.reserveCapacity(serializable.leafs.count)
        for (hash, sLeaf) in serializable.leafs {
            leafPairs.append((hash, serializableDagLeafToCBOR(sLeaf, order: order)))
        }

        return .map(CBOROrderedMap([
            ("Root", .textString(serializable.root)),
            ("Leafs", CBOREncoder.sortedWireMap(leafPairs, order: order)),
        ]))
    }

    /// Serializes the DAG to CBOR format.
    ///
    /// Mirrors Go's `ToCBOR()`. Uses PascalCase field names matching fxamacker/cbor defaults.
    public func toCBOR() -> Data {
        return CBOREncoder().encode(wireValue(order: .cbor))
    }

    /// Deserializes a DAG from CBOR format.
    ///
    /// Mirrors Go's `FromCBOR(data)`.
    public static func fromCBOR(_ data: Data) throws -> Dag {
        return try fromWireValue(CBORDecoder().decode(data))
    }

    /// Decodes the shared wire shape, whichever format it arrived in.
    static func fromWireValue(_ value: CBORValue) throws -> Dag {
        guard let map = value.mapValue else {
            throw DagError.brokenDag("wire root is not a map")
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

func serializableDagLeafToCBOR(_ sLeaf: SerializableDagLeaf, order: WireKeyOrder) -> CBORValue {
    var pairs: [(String, CBORValue)] = [
        ("Hash", .textString(sLeaf.hash)),
        ("ItemName", .textString(sLeaf.itemName)),
        ("Type", .textString(sLeaf.type)),
        ("ContentHash", .optionalBytes(sLeaf.contentHash)),
        ("Content", .optionalBytes(sLeaf.content)),
        ("ClassicMerkleRoot", .byteString(sLeaf.classicMerkleRoot ?? Data())),
        ("CurrentLinkCount", .int(sLeaf.currentLinkCount)),
        ("LeafCount", .int(sLeaf.leafCount)),
        ("ContentSize", .int64(sLeaf.contentSize)),
        ("DagSize", .int64(sLeaf.dagSize)),
        ("Links", .array(sLeaf.links.map { .textString($0) })),
        ("AdditionalData", encodeSortedMapToCBOR(sLeaf.additionalData, order: order)),
    ]

    // stored_proofs is omitted entirely when empty -- Go tags it `omitempty`, and
    // both other ports omit it too. Emitting an empty map here would add a key to
    // every leaf in every full DAG.
    if let sp = sLeaf.storedProofs, !sp.isEmpty {
        let proofPairs = sp.map { ($0.key, serializableProofToCBOR($0.value)) }
        pairs.append(("stored_proofs", CBOREncoder.sortedWireMap(proofPairs, order: order)))
    }

    return .map(CBOROrderedMap(pairs))
}

/// Struct-shaped throughout: Leaf, Proof, Siblings and Path are all declared fields
/// rather than dynamic maps, so nothing here sorts and no key order is needed.
func serializableProofToCBOR(_ sp: SerializableProof) -> CBORValue {
    return .map(CBOROrderedMap([
        ("Leaf", .textString(sp.leaf)),
        ("Proof", .map(CBOROrderedMap([
            ("Siblings", .array(sp.siblings.map { .byteString($0) })),
            ("Path", .unsignedInt(UInt64(sp.path))),
        ]))),
    ]))
}

func encodeSortedMapToCBOR(_ m: [String: String], order: WireKeyOrder) -> CBORValue {
    // AdditionalData is the one wire map with arbitrary, mixed-length keys, so it is
    // the only place the CBOR and JSON comparators can actually disagree.
    return CBOREncoder.sortedWireMap(
        m.map { ($0.key, CBORValue.textString($0.value)) },
        order: order
    )
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

// MARK: - Serializable Packet Types

public struct SerializableTransmissionPacket {
    public var leaf: SerializableDagLeaf = SerializableDagLeaf()
    public var parentHash: String = ""
    public var proofs: [String: SerializableProof]? = nil
}

public struct SerializableBatchedTransmissionPacket {
    public var leaves: [SerializableDagLeaf] = []
    public var relationships: [String: String] = [:]
    public var packetIndex: Int = 0
    public var totalPackets: Int = 0
}

// MARK: - TransmissionPacket Serialization

extension TransmissionPacket {

    public func toSerializable() -> SerializableTransmissionPacket {
        var s = SerializableTransmissionPacket()
        s.leaf = dagLeafToSerializable(leaf)
        s.parentHash = parentHash
        if !proofs.isEmpty {
            var sp: [String: SerializableProof] = [:]
            for (k, v) in proofs {
                sp[k] = SerializableProof(leaf: v.leaf, siblings: v.proof.siblings, path: v.proof.path)
            }
            s.proofs = sp
        }
        return s
    }

    /// Builds the wire tree that BOTH output formats are written from.
    func wireValue(order: WireKeyOrder) -> CBORValue {
        let s = toSerializable()
        var pairs: [(String, CBORValue)] = [
            ("Leaf", serializableDagLeafToCBOR(s.leaf, order: order)),
            ("ParentHash", .textString(s.parentHash)),
        ]
        if let sp = s.proofs, !sp.isEmpty {
            let proofPairs = sp.map { ($0.key, serializableProofToCBOR($0.value)) }
            pairs.append(("proofs", CBOREncoder.sortedWireMap(proofPairs, order: order)))
        }
        return .map(CBOROrderedMap(pairs))
    }

    public func toJSON() throws -> Data {
        return try encodeWireJSON(wireValue(order: .json))
    }

    public func toCBOR() -> Data {
        return CBOREncoder().encode(wireValue(order: .cbor))
    }

    public static func fromJSON(_ data: Data) throws -> TransmissionPacket {
        return try fromWireValue(jsonTransmissionPacketToCBOR(parseWireJSON(data)))
    }

    public static func fromCBOR(_ data: Data) throws -> TransmissionPacket {
        return try fromWireValue(CBORDecoder().decode(data))
    }

    /// Decodes the shared wire shape, whichever format it arrived in.
    static func fromWireValue(_ value: CBORValue) throws -> TransmissionPacket {
        guard let map = value.mapValue else {
            throw DagError.brokenDag("wire packet is not a map")
        }
        var s = SerializableTransmissionPacket()
        if let leafVal = map["Leaf"] { s.leaf = cborToSerializableDagLeaf(leafVal) }
        s.parentHash = map["ParentHash"]?.stringValue ?? ""
        if let proofsMap = map["proofs"]?.mapValue {
            var sp: [String: SerializableProof] = [:]
            for pair in proofsMap.pairs {
                sp[pair.key] = cborToSerializableProof(pair.value)
            }
            s.proofs = sp
        }
        return transmissionPacketFromSerializable(s)
    }
}

// MARK: - BatchedTransmissionPacket Serialization

extension BatchedTransmissionPacket {

    public func toSerializable() -> SerializableBatchedTransmissionPacket {
        var s = SerializableBatchedTransmissionPacket()
        s.leaves = leaves.map { dagLeafToSerializable($0) }
        s.relationships = relationships
        s.packetIndex = packetIndex
        s.totalPackets = totalPackets
        return s
    }

    /// Builds the wire tree that BOTH output formats are written from.
    func wireValue(order: WireKeyOrder) -> CBORValue {
        let s = toSerializable()
        let leavesValue = CBORValue.array(
            s.leaves.map { serializableDagLeafToCBOR($0, order: order) }
        )
        let relationshipPairs = s.relationships.map { ($0.key, CBORValue.textString($0.value)) }

        return .map(CBOROrderedMap([
            ("Leaves", leavesValue),
            ("Relationships", CBOREncoder.sortedWireMap(relationshipPairs, order: order)),
            ("PacketIndex", s.packetIndex >= 0 ? .unsignedInt(UInt64(s.packetIndex)) : .negativeInt(Int64(s.packetIndex))),
            ("TotalPackets", s.totalPackets >= 0 ? .unsignedInt(UInt64(s.totalPackets)) : .negativeInt(Int64(s.totalPackets))),
        ]))
    }

    public func toJSON() throws -> Data {
        return try encodeWireJSON(wireValue(order: .json))
    }

    public func toCBOR() -> Data {
        return CBOREncoder().encode(wireValue(order: .cbor))
    }

    public static func fromCBOR(_ data: Data) throws -> BatchedTransmissionPacket {
        return try fromWireValue(CBORDecoder().decode(data))
    }

    public static func fromJSON(_ data: Data) throws -> BatchedTransmissionPacket {
        return try fromWireValue(jsonBatchedPacketToCBOR(parseWireJSON(data)))
    }

    /// Decodes the shared wire shape, whichever format it arrived in.
    static func fromWireValue(_ value: CBORValue) throws -> BatchedTransmissionPacket {
        guard let map = value.mapValue else {
            throw DagError.brokenDag("wire batched packet is not a map")
        }

        var s = SerializableBatchedTransmissionPacket()
        if let leavesArray = map["Leaves"]?.arrayValue {
            s.leaves = leavesArray.map { cborToSerializableDagLeaf($0) }
        }
        if let relationshipMap = map["Relationships"]?.mapValue {
            for pair in relationshipMap.pairs {
                if let parent = pair.value.stringValue {
                    s.relationships[pair.key] = parent
                }
            }
        }
        s.packetIndex = map["PacketIndex"]?.intValue ?? 0
        s.totalPackets = map["TotalPackets"]?.intValue ?? 0
        return batchedPacketFromSerializable(s)
    }
}

// MARK: - Packet Conversion Helpers

func dagLeafToSerializable(_ leaf: DagLeaf) -> SerializableDagLeaf {
    var s = SerializableDagLeaf()
    s.hash = leaf.hash
    s.itemName = leaf.itemName
    s.type = leaf.type.rawValue
    s.contentHash = leaf.contentHash
    s.content = leaf.content
    s.classicMerkleRoot = leaf.classicMerkleRoot
    s.currentLinkCount = leaf.currentLinkCount
    s.leafCount = leaf.leafCount
    s.contentSize = leaf.contentSize
    s.dagSize = leaf.dagSize
    s.links = leaf.links
    s.additionalData = sortMapByKeys(leaf.additionalData)
    if !leaf.proofs.isEmpty {
        var sp: [String: SerializableProof] = [:]
        for (k, v) in leaf.proofs {
            sp[k] = SerializableProof(leaf: v.leaf, siblings: v.proof.siblings, path: v.proof.path)
        }
        s.storedProofs = sp
    }
    return s
}

func serializableToDagLeaf(_ s: SerializableDagLeaf) -> DagLeaf {
    let leaf = DagLeaf()
    leaf.hash = s.hash
    leaf.itemName = s.itemName
    leaf.type = LeafType(rawValue: s.type) ?? .file
    leaf.contentHash = s.contentHash
    leaf.content = s.content
    leaf.classicMerkleRoot = s.classicMerkleRoot ?? Data()
    leaf.currentLinkCount = s.currentLinkCount
    leaf.leafCount = s.leafCount
    leaf.contentSize = s.contentSize
    leaf.dagSize = s.dagSize
    leaf.links = s.links
    leaf.additionalData = sortMapByKeys(s.additionalData)
    if let sp = s.storedProofs {
        for (k, v) in sp {
            leaf.proofs[k] = ClassicTreeBranch(leaf: v.leaf, proof: Proof(siblings: v.siblings, path: v.path))
        }
    }
    return leaf
}

func transmissionPacketFromSerializable(_ s: SerializableTransmissionPacket) -> TransmissionPacket {
    let leaf = serializableToDagLeaf(s.leaf)
    var proofs: [String: ClassicTreeBranch] = [:]
    if let sp = s.proofs {
        for (k, v) in sp {
            proofs[k] = ClassicTreeBranch(leaf: v.leaf, proof: Proof(siblings: v.siblings, path: v.path))
        }
    }
    return TransmissionPacket(leaf: leaf, parentHash: s.parentHash, proofs: proofs)
}

func batchedPacketFromSerializable(_ s: SerializableBatchedTransmissionPacket) -> BatchedTransmissionPacket {
    return BatchedTransmissionPacket(
        leaves: s.leaves.map { serializableToDagLeaf($0) },
        relationships: s.relationships,
        packetIndex: s.packetIndex,
        totalPackets: s.totalPackets
    )
}
