// ChunkOrder.swift — chunk reassembly ordering
//
// The authoritative ordering key for reassembling a chunked file is the chunk's
// numeric ItemName index, NOT its position in the parent's Links array. Link
// order is not part of a leaf's CID, so every reader re-derives the order here.

import Foundation

/// Extracts a chunk's numeric index from its `ItemName`.
///
/// Chunks are named with a bare index ("0", "1", ...). DAGs written by older
/// builders used a path-prefixed name whose separator depended on the operating
/// system that created them (`file/0` on Unix, `file\0` on Windows), so **both**
/// separators are accepted regardless of the host we are reading on.
///
/// This previously delegated to `NSString.lastPathComponent`, which recognizes
/// only the host's own separator. A Windows-authored legacy name such as
/// `file\10` therefore stayed non-numeric on a POSIX reader, the comparator fell
/// back to lexical order, and chunk 10 was reassembled before chunk 2 — silent
/// content corruption on a DAG that verifies perfectly, because link order is
/// not covered by any hash.
///
/// Mirrors Go's `chunkIndexFromItemName` and Rust's `chunk_index_from_item_name`.
func chunkIndexFromItemName(_ name: String) -> Int? {
    var base = Substring(name)
    if let cut = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        base = name[name.index(after: cut)...]
    }
    return Int(base)
}

/// Orders chunk leaves by chunk index, falling back to lexical order on the full
/// `ItemName` when either name carries no numeric index.
///
/// Mirrors Go's `compareChunkItemNames`, including the fallback comparing the
/// whole original name rather than the extracted basename.
func compareChunkItemNames(_ a: String, _ b: String) -> Bool {
    guard let numA = chunkIndexFromItemName(a),
          let numB = chunkIndexFromItemName(b) else {
        return a < b
    }
    return numA < numB
}
