// What changed between two trees.
//
// Two trees are compared folder by folder. Where both have the same hash under
// a name, everything below it is the same, and nothing below it is read.

/// One difference between an old tree and a new one.
public enum Change: Hashable, Sendable {
    /// The new tree has this entry, and the old one has nothing there. A folder
    /// that was added is one change: what is in it is not listed.
    case added(path: String, entry: Entry)
    /// The old tree has this entry, and the new one has nothing there.
    case removed(path: String, entry: Entry)
    /// Both trees have an entry here, and it differs: a file's bytes, or an
    /// entry's extra data. A folder is listed here only for its extra data.
    /// What differs inside it is listed by its own path.
    case changed(path: String, old: Entry, new: Entry)

    /// Where in the tree the change is: names with `/` between them.
    public var path: String {
        switch self {
        case let .added(path, _), let .removed(path, _), let .changed(path, _, _):
            return path
        }
    }
}

extension Scionic {
    /// The most changes that `diff` lists unless it is told otherwise.
    public static let defaultMaxChanges = 1_000_000
}

private func tooMany(_ most: Int, _ found: Int) -> ScionicError {
    .limitExceeded(what: "the changes between two trees", limit: UInt64(max(most, 0)), requested: UInt64(found))
}

/// The differences between two trees that a store holds, sorted by the bytes of
/// their paths. Both trees must have a folder on top, or be the same tree.
///
/// A change is listed at every place it has. A tree keeps a folder once, however
/// many places the folder has in it, so two small trees can differ at more
/// places than any list holds. More than `most` changes are an error, found as
/// soon as there are that many.
public func diff(_ store: any Store, old: Root, new: Root, most: Int = Scionic.defaultMaxChanges) throws -> [Change] {
    let changes = try findChanges(store, old, new, most)
    if changes.count > most {
        throw tooMany(most, changes.count)
    }
    return changes
}

/// The differences, sorted by path. It stops soon after it has found more than
/// `most`: every pair of folders it looks into holds a change, so the work is
/// held by the same number.
private func findChanges(_ store: any Store, _ old: Root, _ new: Root, _ most: Int) throws -> [Change] {
    let oldTop = try recordOf(store, old).top
    let newTop = try recordOf(store, new).top
    if oldTop == newTop {
        return []
    }
    if oldTop.kind != .folder || newTop.kind != .folder {
        throw invalid("a tree with a file on top has no entries to compare")
    }
    // Each change with the bytes of its path, by which they are sorted.
    var changes: [(path: [UInt8], change: Change)] = []
    var pending: [(old: Target, new: Target, prefix: String, depth: Int)] = [(oldTop, newTop, "", 1)]
    while let (oldFolder, newFolder, prefix, depth) = pending.popLast() {
        if changes.count > most {
            throw tooMany(most, changes.count)
        }
        if depth > Scionic.maxFolderDepth {
            throw ScionicError.tooDeep(limit: Scionic.maxFolderDepth)
        }
        let olds = try folderOf(store, oldFolder).entries
        let news = try folderOf(store, newFolder).entries
        func add(_ change: Change) {
            changes.append((Array(change.path.utf8), change))
        }
        var left = 0
        var right = 0
        while left < olds.count || right < news.count {
            if right == news.count || (left < olds.count && bytesLess(olds[left].nameBytes, news[right].nameBytes)) {
                add(.removed(path: prefix + olds[left].name, entry: olds[left]))
                left += 1
            } else if left == olds.count || bytesLess(news[right].nameBytes, olds[left].nameBytes) {
                add(.added(path: prefix + news[right].name, entry: news[right]))
                right += 1
            } else {
                let (old, new) = (olds[left], news[right])
                let path = prefix + old.name
                if old.kind != new.kind {
                    add(.removed(path: path, entry: old))
                    add(.added(path: path, entry: new))
                } else if old.kind == .file {
                    if old != new {
                        add(.changed(path: path, old: old, new: new))
                    }
                } else {
                    if old.hash != new.hash {
                        pending.append((old.target, new.target, path + "/", depth + 1))
                    }
                    if old.extra != new.extra {
                        add(.changed(path: path, old: old, new: new))
                    }
                }
                left += 1
                right += 1
            }
        }
    }
    // Sorted by the bytes of the paths, and where two changes share a path, a
    // removal before the addition that took its place.
    return changes.enumerated().sorted { a, b in
        if a.element.path != b.element.path {
            return bytesLess(a.element.path, b.element.path)
        }
        return a.offset < b.offset
    }.map(\.element.change)
}
