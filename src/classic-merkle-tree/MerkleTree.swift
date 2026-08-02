// MerkleTree.swift — Classic Merkle Tree types
//
// Ported from the modified go-merkletree (github.com/txaty/go-merkletree).
// Accepts a map of key -> DataBlock (not just an array).

import Foundation

// MARK: - Errors

public enum MerkleTreeError: Error, Equatable {
    case invalidNumOfDataBlocks
    case invalidConfigMode
    case proofIsNil
    case dataBlockIsNil
    case proofInvalidModeTreeNotBuilt
    case proofInvalidDataBlock
    case verificationFailed
    case serializationFailed(String)
}

// MARK: - DataBlock Protocol

/// A data block that can be serialized for hashing in the Merkle tree.
public protocol DataBlock {
    /// Serializes the data block into bytes for hashing.
    func serialize() throws -> Data
}

// MARK: - Proof

/// A Merkle proof for a single leaf in the tree.
public struct Proof {
    /// Sibling hashes along the path from leaf to root.
    public var siblings: [Data]
    /// Bit-packed path indicating whether the node is on the left (1) or right (0) at each level.
    public var path: UInt32

    public init(siblings: [Data] = [], path: UInt32 = 0) {
        self.siblings = siblings
        self.path = path
    }
}

// MARK: - Configuration

/// Configuration mode for the Merkle tree.
public enum MerkleTreeMode: Int {
    case proofGen = 0
    case treeBuild = 1
    case proofGenAndTreeBuild = 2
}

/// Hash function signature: takes bytes, returns hash bytes.
public typealias MerkleHashFunc = (Data) throws -> Data

/// Configuration for Merkle Tree generation.
public struct MerkleTreeConfig {
    public var hashFunc: MerkleHashFunc?
    public var mode: MerkleTreeMode
    public var sortSiblingPairs: Bool
    public var disableLeafHashing: Bool
    public var runInParallel: Bool
    public var numRoutines: Int

    public init(
        hashFunc: MerkleHashFunc? = nil,
        mode: MerkleTreeMode = .proofGen,
        sortSiblingPairs: Bool = false,
        disableLeafHashing: Bool = false,
        runInParallel: Bool = false,
        numRoutines: Int = 0
    ) {
        self.hashFunc = hashFunc
        self.mode = mode
        self.sortSiblingPairs = sortSiblingPairs
        self.disableLeafHashing = disableLeafHashing
        self.runInParallel = runInParallel
        self.numRoutines = numRoutines
    }
}

// MARK: - MerkleTree

/// A Classic Merkle Tree with proof generation and verification.
public class MerkleTree {
    public var config: MerkleTreeConfig
    public var root: Data = Data()
    public var leafHashes: [Data] = []
    public var proofs: [Proof] = []
    public var depth: Int = 0
    public var numLeaves: Int = 0
    public var keys: [String] = []

    // Internal state
    var nodes: [[Data]] = []
    var leafMap: [Data: Int] = [:]
    var hashFunc: MerkleHashFunc!
    var concatFunc: (Data, Data) -> Data = concatHash

    /// True when the tree was built with the default SHA-256 hash function,
    /// letting hot paths stream sibling pairs into one hasher instead of
    /// allocating an intermediate concatenated `Data` per pair.
    var usesDefaultHashPipeline = false

    public init(config: MerkleTreeConfig = MerkleTreeConfig()) {
        self.config = config
    }
}

// MARK: - Hash Concatenation

func concatHash(_ b1: Data, _ b2: Data) -> Data {
    var result = Data(capacity: b1.count + b2.count)
    result.append(b1)
    result.append(b2)
    return result
}

func concatSortHash(_ b1: Data, _ b2: Data) -> Data {
    if b1.lexicographicallyPrecedes(b2) {
        return concatHash(b1, b2)
    }
    return concatHash(b2, b1)
}

// MARK: - Default Hash

public func defaultHashFunc(_ data: Data) throws -> Data {
    return sha256Digest(data)
}

/// Hashes a sibling pair with the default SHA-256 pipeline, streaming both
/// halves into one hasher instead of concatenating them into a temporary
/// buffer first. Byte-identical to `defaultHashFunc(concatFunc(b1, b2))` for
/// both the sorted (`concatSortHash`) and plain (`concatHash`) concat orders.
func defaultPairHash(_ b1: Data, _ b2: Data, sortPairs: Bool) -> Data {
    var hasher = SHA256Hasher()
    if sortPairs && !b1.lexicographicallyPrecedes(b2) {
        hasher.update(b2)
        hasher.update(b1)
    } else {
        hasher.update(b1)
        hasher.update(b2)
    }
    return hasher.finalize()
}
