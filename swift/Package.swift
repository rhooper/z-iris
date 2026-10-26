// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZIris",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ZIrisCore", targets: ["ZIrisCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "ZIrisCore", dependencies: ["TOMLDecoder"]),
        .testTarget(
            name: "ZIrisCoreTests",
            dependencies: ["ZIrisCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
