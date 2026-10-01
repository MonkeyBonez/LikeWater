// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LikeWaterEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LikeWaterEngine", targets: ["LikeWaterEngine"]),
    ],
    targets: [
        .target(name: "LikeWaterEngine"),
        .executableTarget(name: "lwtool", dependencies: ["LikeWaterEngine"]),
        .testTarget(name: "LikeWaterEngineTests", dependencies: ["LikeWaterEngine"],
                    resources: [.copy("Fixtures")]),
    ]
)
