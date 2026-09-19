// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoteLumeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NoteLumeCore", targets: ["NoteLumeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "NoteLumeCore",
            dependencies: [
                "Yams",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "NoteLumeCoreTests", dependencies: ["NoteLumeCore"]),
    ]
)
