// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacWindowClicker",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacWindowClicker", targets: ["MacWindowClicker"])],
    targets: [
        .target(name: "ClickerCore"),
        .executableTarget(name: "MacWindowClicker", dependencies: ["ClickerCore"]),
        .testTarget(name: "ClickerCoreTests", dependencies: ["ClickerCore"])
    ]
)
