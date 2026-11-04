// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidLink",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DroidLink", targets: ["DroidLink"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DroidLink",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "DroidLinkTests",
            dependencies: ["DroidLink"],
            path: "Tests/DroidDockTests"
        )
    ]
)
