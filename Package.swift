// swift-tools-version: 5.9
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
        .library(
            name: "ScionicMerkleTree",
            targets: ["ScionicMerkleTree"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "ScionicMerkleTree",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "src"
        ),
        .testTarget(
            name: "ScionicMerkleTreeTests",
            dependencies: ["ScionicMerkleTree"],
            path: "tests"
        ),
    ]
)