import Foundation
import XCTest
@testable import ScionicMerkleTree

final class CustomTests: XCTestCase {
    func testCreateDagCustom() throws {
        let processor: LeafProcessor = { path, relPath, isDir, isRoot, leafType in
            if isRoot { return nil }

            var data = [
                "path_length": "\(relPath.count)",
                "is_dir": "\(isDir)",
                "leaf_type": leafType.rawValue
            ]

            if !isDir {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attributes[.size] as? NSNumber {
                    data["file_size"] = "\(size.int64Value)"
                }
                data["file_mode"] = "file"
            }

            return data
        }

        try runTestWithAllFixtures { standardDag, fixture, fixturePath in
            let rootAdditionalData = [
                "root_key": "root_value",
                "timestamp": "2025-10-22T00:00:00Z",
                "fixture": fixture.name
            ]

            let customDag = try createDagCustom(path: fixturePath, rootAdditionalData: rootAdditionalData, processor: processor)
            let nilProcessorDag = try createDagAdvanced(path: fixturePath, additionalData: rootAdditionalData)

            let rootLeaf = try XCTUnwrap(customDag.leafs[customDag.root], fixture.name)
            for (key, value) in rootAdditionalData {
                XCTAssertEqual(rootLeaf.additionalData[key], value, fixture.name)
            }
            XCTAssertNil(rootLeaf.additionalData["leaf_type"], fixture.name)

            for (hash, leaf) in customDag.leafs where hash != customDag.root && leaf.type != .chunk {
                XCTAssertEqual(leaf.additionalData["leaf_type"], leaf.type.rawValue, "\(fixture.name): \(leaf.itemName)")
                XCTAssertNotNil(leaf.additionalData["path_length"], "\(fixture.name): \(leaf.itemName)")
                XCTAssertNotNil(leaf.additionalData["is_dir"], "\(fixture.name): \(leaf.itemName)")
                if leaf.type == .file {
                    XCTAssertNotNil(leaf.additionalData["file_size"], "\(fixture.name): \(leaf.itemName)")
                    XCTAssertNotNil(leaf.additionalData["file_mode"], "\(fixture.name): \(leaf.itemName)")
                }
            }

            try customDag.verify()
            let roundTrip = try Dag.fromCBOR(customDag.toCBOR())
            try roundTrip.verify()
            XCTAssertEqual(roundTrip.root, customDag.root, fixture.name)
            XCTAssertEqual(roundTrip.leafs[roundTrip.root]?.additionalData["fixture"], fixture.name)

            let output = try ParityTestHelpers.makeTempDir("custom_output")
            defer { try? FileManager.default.removeItem(atPath: output) }
            try customDag.createDirectory(path: output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output), fixture.name)

            XCTAssertNotEqual(customDag.root, standardDag.root, fixture.name)
            try standardDag.verify()
            try nilProcessorDag.verify()

            let nilRoot = try XCTUnwrap(nilProcessorDag.leafs[nilProcessorDag.root], fixture.name)
            for (key, value) in rootAdditionalData {
                XCTAssertEqual(nilRoot.additionalData[key], value, fixture.name)
            }
            for (hash, leaf) in nilProcessorDag.leafs where hash != nilProcessorDag.root {
                XCTAssertTrue(leaf.additionalData.isEmpty, "\(fixture.name): nil processor added metadata to \(leaf.itemName)")
            }

            let emptyProcessor: LeafProcessor = { _, _, _, _, _ in nil }
            let emptyProcessorDag = try createDagCustom(path: fixturePath, rootAdditionalData: rootAdditionalData, processor: emptyProcessor)
            try emptyProcessorDag.verify()
            XCTAssertEqual(emptyProcessorDag.root, nilProcessorDag.root, fixture.name)
        }
    }
}

