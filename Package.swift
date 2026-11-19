// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyVocab",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MyVocab", targets: ["Lexikos"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .executableTarget(
            name: "Lexikos",
            dependencies: [
                "ZIPFoundation",
                .product(name: "libzstd", package: "zstd"),
            ],
            exclude: ["iOS"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LexikosTests", dependencies: ["Lexikos"]),
    ]
)
