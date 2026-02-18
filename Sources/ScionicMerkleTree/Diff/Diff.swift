// Diff.swift — DAG diffing and patching
//
// Ported from diff/diff.go.
//
// Key types:
//   - DiffType enum: .added, .removed
//   - LeafDiff: type + hash + leaf
//   - DagDiff: diffs map + summary (added/removed/total)
//
// Key functions:
//   - Diff(firstDag, secondDag) -> DagDiff
//   - DiffFromNewLeaves(originalDag, newLeaves) -> DagDiff
//   - DagDiff.getAddedLeaves() -> [String: DagLeaf]
//   - DagDiff.getRemovedLeaves() -> [String: DagLeaf]
//   - DagDiff.applyToDAG(oldDag) -> Dag
//   - DagDiff.createPartialDag(fullNewDag) -> Dag
//
// TODO: Implement in Task #11

import Foundation