// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalLab",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .executable(name: "TerminalLab", targets: ["TerminalLab"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    ],
    targets: [
        .target(
            name: "TerminalCore",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "TerminalLab",
            dependencies: ["TerminalCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "TerminalLabTests",
            dependencies: ["TerminalLab", "TerminalCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        )
    ]
)
