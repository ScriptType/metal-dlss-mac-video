// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MetalDLSSVideo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FrameEngine", targets: ["FrameEngine"]),
        .executable(name: "hdr-probe", targets: ["HDRProbe"]),
        .executable(name: "HDRPlayer", targets: ["HDRPlayer"]),
    ],
    targets: [
        .target(name: "FrameEngine", path: "packages/FrameEngine/Sources"),
        .executableTarget(name: "HDRProbe", dependencies: ["FrameEngine"], path: "tools/HDRProbe"),
        .executableTarget(name: "HDRPlayer", dependencies: ["FrameEngine"],
                          path: "apps/macos/Sources", resources: [.copy("Resources/Controls")]),
        .testTarget(name: "FrameEngineTests", dependencies: ["FrameEngine"], path: "packages/FrameEngine/Tests"),
    ]
)
