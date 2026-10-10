// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalLab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TerminalLab", targets: ["TerminalLab"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    ],
    targets: [
        .executableTarget(
            name: "TerminalLab",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "TerminalLabTests",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        )
    ]
)
