// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScionicMerkleTree",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "ScionicMerkleTree", targets: ["ScionicMerkleTree"]),
    ],
    dependencies: [
        // SHA-256 where the system has none of its own: Apple's systems hash
        // with CryptoKit and Windows with CNG (src/SHA256.swift).
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "ScionicMerkleTree",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .android, .openbsd])
                ),
            ],
            path: "src"
        ),
        // Three programs that use the library as any program would. The README
        // says how to run them, and the tests run what is in them.
        .executableTarget(name: "proofsizes", dependencies: ["ScionicMerkleTree"], path: "examples/proofsizes"),
        .executableTarget(name: "roundtrip", dependencies: ["ScionicMerkleTree"], path: "examples/roundtrip"),
        .executableTarget(name: "speed", dependencies: ["ScionicMerkleTree"], path: "examples/speed"),
        .testTarget(
            name: "ScionicMerkleTreeTests",
            dependencies: ["ScionicMerkleTree", "proofsizes", "roundtrip", "speed"],
            path: "tests"
        ),
    ]
)
