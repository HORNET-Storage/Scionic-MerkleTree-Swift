// Proofsizes shows how small a Merkle branch is beside the list it stands in
// for.
//
//     swift run -c release proofsizes
//
// In a Merkle DAG, checking one child of a parent takes the parent's whole
// list of hashes. Here a parent's list is a Merkle tree of its own, so one
// child is checked with a branch of it. This prints both sizes, in bytes on
// the wire, for folders of ten to a million entries and for files of ten to
// half a million chunks. A file of half a million chunks is about a
// terabyte.

import Foundation
import ScionicMerkleTree

/// The sizes that are measured.
let folderCounts = [10, 1_000, 10_000, 1_000_000]
let fileCounts = [10, 1_000, 10_000, 500_000]

/// How many bytes a store's holder answers a request with.
func answerBytes(_ store: any Store, _ request: Request) throws -> Int {
    var total = 0
    try Responder(store).answer(request.encode()) { frame in
        total += frame.count
    }
    return total
}

/// The name of an entry: 16 bytes long.
func nameOf(_ number: Int) -> String {
    "file-" + column(String(number), 7, with: "0") + ".bin"
}

/// For a folder of so many entries: how many bytes its whole list takes, and
/// how many a branch that shows one entry by its name.
func folderRow(_ count: Int) throws -> (list: Int, branch: Int) {
    let store = MemoryStore()
    let builder = try Builder(store: store, chunking: .fixed(16))
    let file = try builder.file(bytes: Array("the same small file".utf8))
    var entries: [Entry] = []
    entries.reserveCapacity(count)
    for number in 0..<count {
        entries.append(try Entry(name: nameOf(number), target: file))
    }
    let folder = try builder.folder(entries)
    let list = try store.get(.folderList, folder.hash)?.count ?? 0
    let branch = try answerBytes(store, .folderName(folder: folder.hash, name: nameOf(count / 2)))
    return (list, branch)
}

/// For a file of so many chunks: how many bytes its whole list takes, and how
/// many a branch that shows one chunk by its number.
func fileRow(_ count: Int) throws -> (list: Int, branch: Int) {
    // Chunks of one byte, so that a file of many chunks is small.
    let store = MemoryStore()
    let content = (0..<count).map { UInt8($0 % 251) }
    let file = try Builder(store: store, chunking: .fixed(1)).file(bytes: content)
    let list = try store.get(.fileList, file.hash)?.count ?? 0
    let branch = try answerBytes(store, .fileBranch(file: file.hash, start: UInt64(count / 2), count: 1))
    return (list, branch)
}

/// Text at the right of a column so many characters wide.
func column(_ text: String, _ width: Int, with filling: Character = " ") -> String {
    String(repeating: filling, count: max(0, width - text.count)) + text
}

/// One row of a table, as it is printed.
func row(_ count: Int, _ list: Int, _ branch: Int) -> String {
    let smaller = Int((Double(list) / Double(branch)).rounded())
    return column(String(count), 10) + "  " + column(String(list), 12) + "  " + column(String(branch), 8)
        + "  " + column(String(smaller), 9) + "x"
}

/// Prints both tables.
func sizes<Out: TextOutputStream>(to out: inout Out) throws {
    print("One entry of a folder, by its name. Names are 16 bytes long.", to: &out)
    print(heading("entries"), to: &out)
    for count in folderCounts {
        let (list, branch) = try folderRow(count)
        print(row(count, list, branch), to: &out)
    }
    print("", to: &out)
    print("One chunk of a file, by its number.", to: &out)
    print(heading("chunks"), to: &out)
    for count in fileCounts {
        let (list, branch) = try fileRow(count)
        print(row(count, list, branch), to: &out)
    }
}

func heading(_ counted: String) -> String {
    column(counted, 10) + "  " + column("whole list", 12) + "  " + column("branch", 8) + "  " + column("smaller by", 10)
}

/// What the program prints, as it comes.
struct Standard: TextOutputStream {
    mutating func write(_ text: String) {
        Swift.print(text, terminator: "")
    }
}

@main
struct ProofSizes {
    static func main() {
        var out = Standard()
        do {
            try sizes(to: &out)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
