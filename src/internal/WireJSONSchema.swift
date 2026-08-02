// WireJSONSchema.swift — schema-directed JSON -> CBORValue conversion
//
// Converts a parsed `WireJSONValue` into the `CBORValue` tree that the existing
// `cborToSerializable*` decoders already understand, so both wire formats share
// ONE decode schema.
//
// The conversion has to be schema-directed rather than structural because the two
// formats disagree about how bytes travel: JSON carries Content, ContentHash,
// ClassicMerkleRoot and Proof.Siblings as base64 TEXT, CBOR carries them raw. Only
// a walk that knows which field it is looking at can tell a base64 payload from an
// ordinary string like ItemName.
//
// Key ordering is irrelevant here -- this tree is only ever consumed by the
// decoders, never re-encoded -- so these builders emit plain maps and never sort.

import Foundation

// MARK: - Wire keys

/// A wire field name plus the spellings accepted when reading.
///
/// Output always uses `canonical`. The camelCase alias exists so JSON written by
/// older builds of this port, which reached JSON through Codable, still reads back.
/// The Rust port carries the identical table.
struct WireJSONKey {
    let canonical: String
    let spellings: [String]

    init(_ canonical: String, _ spellings: [String]) {
        self.canonical = canonical
        self.spellings = spellings
    }
}

enum WireKeys {
    static let dagRoot = WireJSONKey("Root", ["Root", "root"])
    static let dagLeafs = WireJSONKey("Leafs", ["Leafs", "leafs"])

    static let leafHash = WireJSONKey("Hash", ["Hash", "hash"])
    static let leafItemName = WireJSONKey("ItemName", ["ItemName", "itemName"])
    static let leafType = WireJSONKey("Type", ["Type", "type"])
    static let leafContentHash = WireJSONKey("ContentHash", ["ContentHash", "contentHash"])
    static let leafContent = WireJSONKey("Content", ["Content", "content"])
    static let leafClassicRoot = WireJSONKey(
        "ClassicMerkleRoot", ["ClassicMerkleRoot", "classicMerkleRoot"]
    )
    static let leafCurrentLinkCount = WireJSONKey(
        "CurrentLinkCount", ["CurrentLinkCount", "currentLinkCount"]
    )
    static let leafCount = WireJSONKey("LeafCount", ["LeafCount", "leafCount"])
    static let leafContentSize = WireJSONKey("ContentSize", ["ContentSize", "contentSize"])
    static let leafDagSize = WireJSONKey("DagSize", ["DagSize", "dagSize"])
    static let leafLinks = WireJSONKey("Links", ["Links", "links"])
    static let leafAdditionalData = WireJSONKey(
        "AdditionalData", ["AdditionalData", "additionalData"]
    )
    static let leafStoredProofs = WireJSONKey(
        "stored_proofs", ["stored_proofs", "storedProofs"]
    )

    static let branchLeaf = WireJSONKey("Leaf", ["Leaf", "leaf"])
    static let branchProof = WireJSONKey("Proof", ["Proof", "proof"])
    static let proofSiblings = WireJSONKey("Siblings", ["Siblings", "siblings"])
    static let proofPath = WireJSONKey("Path", ["Path", "path"])

    static let packetParentHash = WireJSONKey("ParentHash", ["ParentHash", "parentHash"])
    static let packetProofs = WireJSONKey("proofs", ["proofs"])
    static let batchLeaves = WireJSONKey("Leaves", ["Leaves", "leaves"])
    static let batchRelationships = WireJSONKey(
        "Relationships", ["Relationships", "relationships"]
    )
    static let batchPacketIndex = WireJSONKey("PacketIndex", ["PacketIndex", "packetIndex"])
    static let batchTotalPackets = WireJSONKey("TotalPackets", ["TotalPackets", "totalPackets"])
}

// MARK: - Lookup helpers

/// Finds a field by any accepted spelling.
///
/// Rejects a document that carries the same field under two spellings at once:
/// there would be no principled way to choose, and silently preferring one would
/// make the decode depend on key order.
func jsonGet(
    _ object: [(key: String, value: WireJSONValue)],
    _ key: WireJSONKey
) throws -> WireJSONValue? {
    var found: WireJSONValue? = nil
    var foundSpelling: String? = nil
    for pair in object where key.spellings.contains(pair.key) {
        if let existing = foundSpelling, existing != pair.key {
            throw DagError.brokenDag(
                "\(key.canonical) appears under two spellings (\(existing), \(pair.key))"
            )
        }
        found = pair.value
        foundSpelling = pair.key
    }
    return found
}

func jsonObject(
    _ value: WireJSONValue,
    _ field: String
) throws -> [(key: String, value: WireJSONValue)] {
    guard case .object(let pairs) = value else {
        throw DagError.brokenDag("\(field) is not an object")
    }
    return pairs
}

func jsonString(_ value: WireJSONValue, _ field: String) throws -> String {
    guard case .string(let text) = value else {
        throw DagError.brokenDag("\(field) is not text")
    }
    return text
}

func jsonRequiredString(_ value: WireJSONValue?, _ field: String) throws -> String {
    guard let value else {
        throw DagError.brokenDag("missing \(field)")
    }
    return try jsonString(value, field)
}

func decodeWireBase64(_ text: String, _ field: String) throws -> Data {
    guard let data = Data(base64Encoded: text) else {
        throw DagError.brokenDag("\(field) is not valid base64")
    }
    return data
}

// MARK: - Field copiers

func copyJSONText(
    _ object: [(key: String, value: WireJSONValue)],
    _ key: WireJSONKey,
    into output: inout [(String, CBORValue)]
) throws {
    guard let value = try jsonGet(object, key) else { return }
    switch value {
    case .null: output.append((key.canonical, .null))
    case .string(let text): output.append((key.canonical, .textString(text)))
    default: throw DagError.brokenDag("\(key.canonical) is not text")
    }
}

func copyJSONBytes(
    _ object: [(key: String, value: WireJSONValue)],
    _ key: WireJSONKey,
    into output: inout [(String, CBORValue)]
) throws {
    guard let value = try jsonGet(object, key) else { return }
    switch value {
    case .null: output.append((key.canonical, .null))
    case .string(let text):
        output.append((key.canonical, .byteString(try decodeWireBase64(text, key.canonical))))
    default: throw DagError.brokenDag("\(key.canonical) is not base64 text")
    }
}

func copyJSONNumber(
    _ object: [(key: String, value: WireJSONValue)],
    _ key: WireJSONKey,
    into output: inout [(String, CBORValue)]
) throws {
    guard let value = try jsonGet(object, key) else { return }
    switch value {
    case .null: output.append((key.canonical, .null))
    case .number(let number): output.append((key.canonical, .unsignedInt(number)))
    default: throw DagError.brokenDag("\(key.canonical) is not an unsigned integer")
    }
}

// MARK: - Schema walks

func jsonDagToCBOR(_ value: WireJSONValue) throws -> CBORValue {
    let object = try jsonObject(value, "DAG")
    let root = try jsonRequiredString(try jsonGet(object, WireKeys.dagRoot), "Root")
    guard let leafsValue = try jsonGet(object, WireKeys.dagLeafs) else {
        throw DagError.brokenDag("missing Leafs")
    }
    let leafs = try jsonObject(leafsValue, "Leafs")
    var leafPairs: [(String, CBORValue)] = []
    leafPairs.reserveCapacity(leafs.count)
    for pair in leafs {
        leafPairs.append((pair.key, try jsonLeafToCBOR(pair.value)))
    }
    return .map(CBOROrderedMap([
        ("Root", .textString(root)),
        ("Leafs", .map(CBOROrderedMap(leafPairs))),
    ]))
}

func jsonLeafToCBOR(_ value: WireJSONValue) throws -> CBORValue {
    let object = try jsonObject(value, "leaf")
    var pairs: [(String, CBORValue)] = []
    try copyJSONText(object, WireKeys.leafHash, into: &pairs)
    try copyJSONText(object, WireKeys.leafItemName, into: &pairs)
    try copyJSONText(object, WireKeys.leafType, into: &pairs)
    try copyJSONBytes(object, WireKeys.leafContentHash, into: &pairs)
    try copyJSONBytes(object, WireKeys.leafContent, into: &pairs)
    try copyJSONBytes(object, WireKeys.leafClassicRoot, into: &pairs)
    try copyJSONNumber(object, WireKeys.leafCurrentLinkCount, into: &pairs)
    try copyJSONNumber(object, WireKeys.leafCount, into: &pairs)
    try copyJSONNumber(object, WireKeys.leafContentSize, into: &pairs)
    try copyJSONNumber(object, WireKeys.leafDagSize, into: &pairs)

    if let linksValue = try jsonGet(object, WireKeys.leafLinks) {
        switch linksValue {
        case .null:
            pairs.append((WireKeys.leafLinks.canonical, .null))
        case .array(let values):
            var links: [CBORValue] = []
            links.reserveCapacity(values.count)
            for entry in values {
                links.append(.textString(try jsonString(entry, "Links entry")))
            }
            pairs.append((WireKeys.leafLinks.canonical, .array(links)))
        default:
            throw DagError.brokenDag("Links is not an array")
        }
    }

    if let metadataValue = try jsonGet(object, WireKeys.leafAdditionalData) {
        switch metadataValue {
        case .null:
            pairs.append((WireKeys.leafAdditionalData.canonical, .null))
        case .object(let entries):
            var metadata: [(String, CBORValue)] = []
            metadata.reserveCapacity(entries.count)
            for entry in entries {
                metadata.append((entry.key, .textString(try jsonString(entry.value, "metadata value"))))
            }
            pairs.append((WireKeys.leafAdditionalData.canonical, .map(CBOROrderedMap(metadata))))
        default:
            throw DagError.brokenDag("AdditionalData is not an object")
        }
    }

    if let proofsValue = try jsonGet(object, WireKeys.leafStoredProofs) {
        switch proofsValue {
        case .null:
            pairs.append((WireKeys.leafStoredProofs.canonical, .null))
        case .object(let entries):
            var proofs: [(String, CBORValue)] = []
            proofs.reserveCapacity(entries.count)
            for entry in entries {
                proofs.append((entry.key, try jsonProofToCBOR(entry.value)))
            }
            pairs.append((WireKeys.leafStoredProofs.canonical, .map(CBOROrderedMap(proofs))))
        default:
            throw DagError.brokenDag("stored_proofs is not an object")
        }
    }

    return .map(CBOROrderedMap(pairs))
}

func jsonProofToCBOR(_ value: WireJSONValue) throws -> CBORValue {
    let object = try jsonObject(value, "stored proof")
    let child = try jsonRequiredString(try jsonGet(object, WireKeys.branchLeaf), "Leaf")

    // Go nests Siblings/Path under Proof. A flattened shape is tolerated because a
    // branch that omits the wrapper is unambiguous -- there is nothing else it
    // could mean -- and the Rust port accepts it identically.
    let proofObject: [(key: String, value: WireJSONValue)]
    if let nested = try jsonGet(object, WireKeys.branchProof) {
        proofObject = try jsonObject(nested, "Proof")
    } else {
        proofObject = object
    }

    var siblings: [CBORValue] = []
    if let siblingsValue = try jsonGet(proofObject, WireKeys.proofSiblings) {
        switch siblingsValue {
        case .null:
            break
        case .array(let values):
            siblings.reserveCapacity(values.count)
            for entry in values {
                let text = try jsonString(entry, "proof sibling")
                siblings.append(.byteString(try decodeWireBase64(text, "proof sibling")))
            }
        default:
            throw DagError.brokenDag("proof Siblings is not an array")
        }
    }

    var path: UInt64 = 0
    if let pathValue = try jsonGet(proofObject, WireKeys.proofPath) {
        switch pathValue {
        case .null: path = 0
        case .number(let number): path = number
        default: throw DagError.brokenDag("proof Path is not an unsigned integer")
        }
    }

    return .map(CBOROrderedMap([
        ("Leaf", .textString(child)),
        ("Proof", .map(CBOROrderedMap([
            ("Siblings", .array(siblings)),
            ("Path", .unsignedInt(path)),
        ]))),
    ]))
}

func jsonTransmissionPacketToCBOR(_ value: WireJSONValue) throws -> CBORValue {
    let object = try jsonObject(value, "transmission packet")
    guard let leafValue = try jsonGet(object, WireKeys.branchLeaf) else {
        throw DagError.brokenDag("missing transmission packet Leaf")
    }
    var pairs: [(String, CBORValue)] = [
        ("Leaf", try jsonLeafToCBOR(leafValue)),
    ]

    if let parentValue = try jsonGet(object, WireKeys.packetParentHash) {
        switch parentValue {
        case .null: pairs.append(("ParentHash", .textString("")))
        case .string(let text): pairs.append(("ParentHash", .textString(text)))
        default: throw DagError.brokenDag("ParentHash is not text")
        }
    }

    if let proofsValue = try jsonGet(object, WireKeys.packetProofs) {
        switch proofsValue {
        case .null:
            break
        case .object(let entries):
            var proofs: [(String, CBORValue)] = []
            proofs.reserveCapacity(entries.count)
            for entry in entries {
                proofs.append((entry.key, try jsonProofToCBOR(entry.value)))
            }
            pairs.append(("proofs", .map(CBOROrderedMap(proofs))))
        default:
            throw DagError.brokenDag("proofs is not an object")
        }
    }

    return .map(CBOROrderedMap(pairs))
}

func jsonBatchedPacketToCBOR(_ value: WireJSONValue) throws -> CBORValue {
    let object = try jsonObject(value, "batched transmission packet")

    var leaves: [CBORValue] = []
    if let leavesValue = try jsonGet(object, WireKeys.batchLeaves) {
        switch leavesValue {
        case .null:
            break
        case .array(let values):
            leaves.reserveCapacity(values.count)
            for entry in values {
                leaves.append(try jsonLeafToCBOR(entry))
            }
        default:
            throw DagError.brokenDag("Leaves is not an array")
        }
    }

    var relationships: [(String, CBORValue)] = []
    if let relationshipsValue = try jsonGet(object, WireKeys.batchRelationships) {
        switch relationshipsValue {
        case .null:
            break
        case .object(let entries):
            relationships.reserveCapacity(entries.count)
            for entry in entries {
                relationships.append(
                    (entry.key, .textString(try jsonString(entry.value, "relationship parent")))
                )
            }
        default:
            throw DagError.brokenDag("Relationships is not an object")
        }
    }

    var pairs: [(String, CBORValue)] = [
        ("Leaves", .array(leaves)),
        ("Relationships", .map(CBOROrderedMap(relationships))),
    ]
    try copyJSONNumber(object, WireKeys.batchPacketIndex, into: &pairs)
    try copyJSONNumber(object, WireKeys.batchTotalPackets, into: &pairs)
    return .map(CBOROrderedMap(pairs))
}
