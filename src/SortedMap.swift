/// A map that keeps its keys in order, for the lists and chunks an intake
/// still wants: it is asked for the first of them, and for the first so many,
/// in order, as often as a fetch asks for more.
///
/// It is a list of short sorted runs, so a key is put in or taken out by
/// moving at most one run, and the order costs nothing to read.
struct SortedMap<Key: Comparable, Value> {
    private var runs: [[(key: Key, value: Value)]] = []
    private(set) var count = 0
    private let runLength = 256

    var isEmpty: Bool {
        count == 0
    }

    /// The run where `key` is or would be: the last one whose first key is not
    /// after it, or the first run.
    private func run(for key: Key) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if runs[middle][0].key <= key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low - 1, 0)
    }

    /// Where `key` is or would be in run `run`.
    private func place(of key: Key, in run: Int) -> (index: Int, found: Bool) {
        let items = runs[run]
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].key < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return (low, low < items.count && items[low].key == key)
    }

    func get(_ key: Key) -> Value? {
        if runs.isEmpty {
            return nil
        }
        let run = run(for: key)
        let (index, found) = place(of: key, in: run)
        return found ? runs[run][index].value : nil
    }

    /// Puts `value` under `key`, in place of what was there.
    mutating func insert(_ key: Key, _ value: Value) {
        if runs.isEmpty {
            runs.append([(key, value)])
            count = 1
            return
        }
        let run = run(for: key)
        let (index, found) = place(of: key, in: run)
        if found {
            runs[run][index].value = value
            return
        }
        runs[run].insert((key, value), at: index)
        count += 1
        if runs[run].count >= 2 * runLength {
            let upper = Array(runs[run][runLength...])
            runs[run].removeLast(runs[run].count - runLength)
            runs.insert(upper, at: run + 1)
        }
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Value? {
        if runs.isEmpty {
            return nil
        }
        let run = run(for: key)
        let (index, found) = place(of: key, in: run)
        if !found {
            return nil
        }
        let value = runs[run].remove(at: index).value
        count -= 1
        if runs[run].isEmpty {
            runs.remove(at: run)
        }
        return value
    }

    var first: (key: Key, value: Value)? {
        runs.first?.first
    }

    /// Calls `body` with each key and value in order, until it says to stop.
    func forEach(_ body: (Key, Value) throws -> Bool) rethrows {
        for run in runs {
            for item in run {
                if try !body(item.key, item.value) {
                    return
                }
            }
        }
    }
}
