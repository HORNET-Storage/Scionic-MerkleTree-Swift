// Serialization.swift — JSON and CBOR serialization/deserialization
//
// Ported from dag/serialize.go.
//
// Key types:
//   - SerializableDag / SerializableDagLeaf — intermediate representation
//
// Key functions:
//   - Dag.toSerializable() -> SerializableDag
//   - Dag.toCBOR() -> Data
//   - Dag.toJSON() -> Data
//   - Dag.fromCBOR(data) -> Dag
//   - Dag.fromJSON(data) -> Dag
//   - FromSerializable(serializable) -> Dag (rebuilds MerkleTrees from links)
//   - TransmissionPacket serialization (CBOR + JSON)
//   - BatchedTransmissionPacket serialization (CBOR + JSON)
//
// TODO: Implement in Task #9

import Foundation