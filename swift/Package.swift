// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZIris",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ZIrisCore", targets: ["ZIrisCore"]),
        .library(name: "ZulipKit", targets: ["ZulipKit"]),
        .executable(name: "z-iris", targets: ["ZIrisApp"]),
        .executable(name: "z-iris-priority", targets: ["ZIrisPriority"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(
            name: "ZIrisCore",
            dependencies: ["TOMLDecoder"],
            resources: [.copy("Resources/emoji.json")]
        ),
        .target(name: "ZulipKit", dependencies: ["ZIrisCore"]),
        .target(name: "ZIrisMac", dependencies: ["ZIrisCore", "ZulipKit"]),
        .executableTarget(name: "ZIrisApp", dependencies: ["ZIrisCore", "ZulipKit", "ZIrisMac"]),
        .executableTarget(name: "ZIrisPriority", dependencies: ["ZIrisMac"]),
        .testTarget(name: "ZIrisMacTests", dependencies: ["ZIrisMac", "ZIrisCore"]),
        .testTarget(
            name: "ZulipKitTests",
            dependencies: ["ZulipKit", "ZIrisCore"]
        ),
        .testTarget(
            name: "ZIrisCoreTests",
            dependencies: ["ZIrisCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
