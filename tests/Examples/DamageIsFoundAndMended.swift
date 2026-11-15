import ScionicMerkleTree
import XCTest

final class DamageIsFoundAndMendedExample: XCTestCase {
    // Bytes that were harmed where a store keeps them are found when the tree
    // is verified, named by their hash, and fetched again on their own.
    func testDamageIsFoundAndMended() throws {
        var printed: [String] = []
        func print(_ items: Any...) {
            printed.append(items.map { "\($0)" }.joined(separator: " "))
        }

        // A tree in two stores: a publisher's, and a mirror of it.
        let publisher = MemoryStore()
        let builder = Builder(store: publisher, chunking: .fastCDCv1)
        let weights = try builder.file(bytes: [UInt8](repeating: 7, count: 3 << 20))
        let root = try builder.finish(top: weights)
        let mirror = MemoryStore()
        _ = try fetch(mirror, root, from: Responder(publisher))

        // A chunk is harmed where the mirror keeps it.
        let chunk = mirror.hashes(.chunk)[0]
        try mirror.remove(.chunk, chunk)
        try mirror.put(.chunk, chunk, Array("not what the hash says".utf8))

        // Verifying finds the damage, and the error names what was harmed.
        do {
            _ = try verify(mirror, root)
        } catch ScionicError.corrupt(_, let hash) {
            print("the damaged chunk is named:", hash == chunk)
        }

        // With discardDamaged the damaged parts are removed, and the next fetch
        // brings back exactly those.
        do {
            _ = try verify(mirror, root, options: VerifyOptions(discardDamaged: true))
        } catch ScionicError.missing {
            print("it is missing now")
        }
        _ = try fetch(mirror, root, from: Responder(publisher))
        _ = try verify(mirror, root)
        print("the tree is whole again")

        XCTAssertEqual(printed, ["the damaged chunk is named: true", "it is missing now", "the tree is whole again"])
    }
}
