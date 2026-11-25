// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ATK",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATK", targets: ["ATKMouse"]),
        .executable(name: "atk-cli", targets: ["ATKMouseCLI"]),
    ],
    targets: [
        .target(name: "ATKMouseCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "ATKMouse", dependencies: ["ATKMouseCore"]),
        .executableTarget(name: "ATKMouseCLI", dependencies: ["ATKMouseCore"]),
        .testTarget(name: "ATKMouseCoreTests", dependencies: ["ATKMouseCore"]),
    ]
)
