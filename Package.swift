// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZooCove",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ZooCove", targets: ["ZooCove"])],
    targets: [
        .target(name: "ThreadIslandCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ZooCove", dependencies: ["ThreadIslandCore"], path: "Sources/ThreadIsland"),
        .testTarget(name: "ThreadIslandCoreTests", dependencies: ["ThreadIslandCore"])
    ]
)
