// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZIris",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ZIrisCore", targets: ["ZIrisCore"]),
    ],
    targets: [
        .target(name: "ZIrisCore"),
        .testTarget(
            name: "ZIrisCoreTests",
            dependencies: ["ZIrisCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
