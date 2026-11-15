// Speed measures how fast the parts of building and checking a tree are, on
// one file held in memory, so that no disk is in the way.
//
//     swift run -c release speed [MiB [folder]]
//
// It prints, for a file of that many MiB of bytes that look random: chunking
// alone, hashing alone, building the file into a store in memory, and
// checking every chunk of it again. Without a number, the file is 1 GiB.
//
// With a folder, it also builds that folder from disk into a store in
// memory, and prints the best of five runs: by then the system holds the
// files in memory, so it is the library that is measured and not the disk.

import Foundation
import ScionicMerkleTree

/// Bytes that look random and cost little to make: a xorshift generator. The
/// Rust and Go libraries' examples make the same bytes, so the three print the
/// same root.
func filler(_ length: Int) -> [UInt8] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    return [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
        var at = 0
        while at < length {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // The low byte first.
            var word = state
            for _ in 0..<min(8, length - at) {
                buffer[at] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                at += 1
            }
        }
        initialized = length
    }
}

/// How many seconds have gone by since `started`.
func seconds(since started: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
}

/// A step's name, in a column of its own.
func step(_ name: String) -> String {
    name.padding(toLength: 22, withPad: " ", startingAt: 0)
}

func report<Out: TextOutputStream>(_ out: inout Out, _ name: String, _ taken: Double, _ size: Int) {
    let rate = Double(size) / Double(1 << 20) / max(taken, 1e-9)
    print(step(name) + " " + String(format: "%7.3f s  %8.0f MiB/s", taken, rate), to: &out)
}

/// Measures the parts on a file of so many MiB, and the building of `folder`
/// if one is named. It gives the root of the file's tree.
func speed<Out: TextOutputStream>(_ megabytes: Int, _ folder: String?, to out: inout Out) throws -> Root {
    let data = filler(megabytes << 20)

    var started = DispatchTime.now()
    let chunks = Chunking.fastCDCv1.cut(data)
    report(&out, "chunked", seconds(since: started), data.count)
    print(step("") + " \(chunks.count) chunks", to: &out)

    started = DispatchTime.now()
    var mixed: UInt8 = 0
    for chunk in chunks {
        mixed ^= Hash.of(chunk).withUnsafeBytes { $0[0] }
    }
    report(&out, "hashed", seconds(since: started), data.count)

    let store = MemoryStore()
    started = DispatchTime.now()
    let builder = Builder(store: store, chunking: .fastCDCv1)
    let file = try builder.file(bytes: data)
    report(&out, "built", seconds(since: started), data.count)

    let root = try builder.finish(top: file)
    started = DispatchTime.now()
    _ = try verify(store, root)
    report(&out, "checked", seconds(since: started), data.count)
    let hex = String(mixed, radix: 16)
    print("root \(root) (\(hex.count < 2 ? "0" + hex : hex))", to: &out)

    if let folder {
        var best = Double.greatestFiniteMagnitude
        var size: UInt64 = 0
        var files = 0
        for _ in 0..<5 {
            let store = MemoryStore()
            let started = DispatchTime.now()
            let built = try build(store, path: folder)
            best = min(best, seconds(since: started))
            size = try recordOf(store, built).top.size
            files = store.count(.fileList)
        }
        report(&out, "built from disk", best, Int(clamping: size))
        print(step("") + " \(files) different files, \(size) bytes", to: &out)
    }
    return root
}

/// What the program prints, as it comes.
struct Standard: TextOutputStream {
    mutating func write(_ text: String) {
        Swift.print(text, terminator: "")
    }
}

@main
struct Speed {
    static func main() {
        let arguments = CommandLine.arguments
        var megabytes = 1024
        if arguments.count > 1 {
            guard let given = Int(arguments[1]), given >= 0, given <= 1 << 20 else {
                FileHandle.standardError.write(Data("usage: speed [MiB [folder]]\n".utf8))
                exit(2)
            }
            megabytes = given
        }
        var out = Standard()
        do {
            _ = try speed(megabytes, arguments.count > 2 ? arguments[2] : nil, to: &out)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
