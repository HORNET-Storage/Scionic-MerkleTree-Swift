// Utils.swift — Utility functions for DAG operations
//
// Ported from dag/utils.go.

import Foundation

// MARK: - KeyValue (for CBOR serialization)

/// A key-value pair used for deterministic CBOR encoding of AdditionalData.
///
/// Maps are converted to sorted `[KeyValue]` arrays before CBOR encoding,
/// ensuring deterministic byte output regardless of dictionary iteration order.
public struct KeyValue {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// Converts to CBORValue (a CBOR map with "Key" and "Value" fields).
    /// Matches Go's `KeyValue{Key: ..., Value: ...}` struct CBOR encoding.
    public func toCBOR() -> CBORValue {
        return .map(CBOROrderedMap([
            ("Key", .textString(key)),
            ("Value", .textString(value)),
        ]))
    }
}

// MARK: - Map Sorting

/// Converts a map to a sorted array of KeyValue pairs for deterministic CBOR encoding.
///
/// Mirrors Go's `SortMapForVerification`. Returns nil if the input map is nil.
/// This nil vs empty distinction is critical for CBOR encoding:
///   - nil map → nil → CBOR null (0xf6)
///   - empty map → [] → CBOR empty array (0x80)
public func sortMapForVerification(_ inputMap: [String: String]?) -> [KeyValue]? {
    guard let inputMap = inputMap else {
        return nil
    }

    if inputMap.isEmpty {
        return []
    }

    let sortedKeys = inputMap.keys.sorted()
    return sortedKeys.map { KeyValue(key: $0, value: inputMap[$0]!) }
}

/// Sorts a map by keys and returns a new dictionary.
///
/// Mirrors Go's `SortMapByKeys`. Note: Swift dictionaries don't preserve order,
/// but this ensures consistency when the map is later passed to `sortMapForVerification`.
/// Returns an empty dictionary for nil or empty input.
public func sortMapByKeys(_ inputMap: [String: String]?) -> [String: String] {
    guard let inputMap = inputMap, !inputMap.isEmpty else {
        return [:]
    }
    // In Swift, Dictionary is inherently unordered, so "sorting" just means
    // returning a copy. The actual sorting happens in sortMapForVerification
    // when we need deterministic order for CBOR encoding.
    return inputMap
}

// MARK: - Size Calculation

/// Calculates the total content size across all leaves in the DAG.
public func calculateTotalContentSize(_ dag: Dag) -> Int64 {
    var totalSize: Int64 = 0
    for (_, leaf) in dag.leafs {
        if let content = leaf.content {
            totalSize += Int64(content.count)
        }
    }
    return totalSize
}

/// Calculates the total serialized DAG size by CBOR-encoding each leaf.
///
/// This mirrors Go's `CalculateTotalDagSize` which serializes a full struct
/// per leaf (including all fields) to determine the wire size.
public func calculateTotalDagSize(_ dag: Dag) throws -> Int64 {
    let encoder = CBOREncoder()
    var totalSize: Int64 = 0

    for (_, leaf) in dag.leafs {
        var linkHashes: [String] = []
        if !leaf.links.isEmpty {
            linkHashes = leaf.links.sorted()
        }

        let linksValue: CBORValue = linkHashes.isEmpty
            ? .null
            : .array(linkHashes.map { .textString($0) })

        let data = encoder.encodeMap([
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
            ("AdditionalData", .map(CBOROrderedMap(
                sortMapByKeys(leaf.additionalData).sorted(by: { $0.key < $1.key })
                    .map { ($0.key, CBORValue.textString($0.value)) }
            ))),
        ])

        totalSize += Int64(data.count)
    }

    return totalSize
}
