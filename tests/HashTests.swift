import XCTest
@testable import ScionicMerkleTree

final class HashTests: XCTestCase {
    func testAHashIsTheSHA256OfTheBytes() {
        XCTAssertEqual(Hash.of(bytes("abc")).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hash.of([]).hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAHashReadsBackFromItsHex() throws {
        let hash = Hash.of(bytes("abc"))
        XCTAssertEqual(try Hash(hex: hash.hex), hash)
        XCTAssertEqual("\(hash)", hash.hex)
        XCTAssertThrowsError(try Hash(hex: hash.hex.uppercased()))
        XCTAssertThrowsError(try Hash(hex: String(hash.hex.dropLast())))
        XCTAssertThrowsError(try Hash(bytes: [UInt8](repeating: 0, count: 31)))
    }

    func testHashesCompareAsTheirBytesDo() {
        var numbers = Numbers(0x1234_5678_9abc_def1)
        for _ in 0..<500 {
            let a = (0..<32).map { _ in UInt8(numbers.next(3)) }
            let b = (0..<32).map { _ in UInt8(numbers.next(3)) }
            let ha = try! Hash(bytes: a)
            let hb = try! Hash(bytes: b)
            XCTAssertEqual(ha < hb, a.lexicographicallyPrecedes(b))
            XCTAssertEqual(ha == hb, a == b)
            XCTAssertEqual(ha.bytes, a)
        }
    }

    func testARootIsWrittenAsACIDThatBeginsBafkrei() throws {
        let root = Root.of(record: bytes("abc"))
        let text = root.text
        XCTAssertEqual(text.utf8.count, 59)
        XCTAssertTrue(text.hasPrefix("bafkrei"), text)
        // The CID of the raw bytes "abc", as other tools write it.
        XCTAssertEqual(text, "bafkreif2pall7dybz7vecqka3zo24irdwabwdi4wc55jznaq75q7eaavvu")
        XCTAssertEqual(try Root(text: text), root)
    }

    func testOnlyTheOneSpellingOfARootIsRead() {
        let text = Root.of(record: bytes("abc")).text
        let oldLayout = "bafirei" + text.dropFirst(7)
        for other in [
            text.uppercased(),
            String(text.dropFirst()),
            String(text.prefix(58)),
            text + "a",
            oldLayout,
            text + "=",
            "",
        ] {
            XCTAssertThrowsError(try Root(text: other), other)
        }
        // The last letter carries two bits that must be zero.
        var letters = Array(text.utf8)
        letters[letters.count - 1] = letters.last == UInt8(ascii: "b") ? UInt8(ascii: "c") : UInt8(ascii: "b")
        let changed = String(decoding: letters, as: UTF8.self)
        XCTAssertThrowsError(try Root(text: changed), changed)
    }

    func testBase32ReadsBackWhatItWritesAtEveryLength() throws {
        let all = (0..<64).map { UInt8(($0 * 37) % 251) }
        for length in 0..<all.count {
            let text = base32Lower(Array(all[..<length]))
            XCTAssertEqual(try base32LowerDecode(text.utf8), Array(all[..<length]))
        }
        XCTAssertEqual(base32Lower(bytes("foobar")), "mzxw6ytboi")
    }

    func testBase32RefusesOtherLettersAndLeftoverBits() throws {
        for text in ["MZXW6", "mzxw1", "mzxw=", "mz xw", "mzxw6ytbo1"] {
            XCTAssertThrowsError(try base32LowerDecode(text.utf8), text)
        }
        // "my" is one byte and two bits that are zero; "mz" leaves a bit set.
        XCTAssertEqual(try base32LowerDecode("my".utf8), [0x66])
        XCTAssertEqual(base32Lower([0x66]), "my")
        XCTAssertThrowsError(try base32LowerDecode("mz".utf8))
    }

    func testHexReadsBackWhatItWritesAndRefusesTheRest() throws {
        let all: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xAB, 0xFF]
        let text = hexLower(all)
        XCTAssertEqual(text, "00017f80abff")
        var back = [UInt8](repeating: 0, count: 6)
        try hexLowerDecode(text, into: &back)
        XCTAssertEqual(back, all)
        for text in ["00017F80ABFF", "00017f80abf", "00017f80abfff", "00017f80abfg"] {
            XCTAssertThrowsError(try hexLowerDecode(text, into: &back), text)
        }
    }

    func testAnEmptyAndALongInputHashAsSHA256Does() {
        // The two ways the system's SHA-256 is called: with nothing to read,
        // and with more than fits one call on Windows is not tried here (4 GiB),
        // but a few megabytes in one call are.
        let long = [UInt8](repeating: 0x61, count: 1_000_000)
        XCTAssertEqual(Hash.of(long).hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        XCTAssertEqual(Hash.of(ArraySlice<UInt8>()).hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
