// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Grove",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "GroveCore",
            targets: ["GroveCore"]
        ),
        .executable(
            name: "Grove",
            targets: ["Grove"]
        )
    ],
    targets: [
        .target(
            name: "GroveCore",
            path: "Sources/GroveCore"
        ),
        .executableTarget(
            name: "Grove",
            dependencies: ["GroveCore"],
            path: "Sources/Grove"
        ),
        .testTarget(
            name: "GroveTests",
            dependencies: ["GroveCore"],
            path: "Tests/GroveTests"
        )
    ]
)
