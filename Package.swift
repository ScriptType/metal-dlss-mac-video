// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MetalDLSSVideo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FrameEngine", targets: ["FrameEngine"]),
        .library(name: "FrameEngineShared", type: .dynamic, targets: ["FrameEngine"]),
        .executable(name: "hdr-probe", targets: ["HDRProbe"]),
        .executable(name: "hdr-benchmark", targets: ["FrameBenchmark"]),
        .executable(name: "HDRPlayer", targets: ["HDRPlayer"]),
        .executable(name: "HDRHarness", targets: ["HDRHarness"]),
    ],
    dependencies: [.package(path: "vendor/MLX-DLSS")],
    targets: [
        .target(name: "CFrameEngine", path: "packages/CFrameEngine", publicHeadersPath: "include"),
        .systemLibrary(name: "CMpv", path: "packages/CMpv"),
        .target(name: "FrameEngine", dependencies: ["CFrameEngine", .product(name: "DLSSMedia", package: "MLX-DLSS"), .product(name: "DLSSMLX", package: "MLX-DLSS")], path: "packages/FrameEngine/Sources"),
        .executableTarget(name: "HDRProbe", dependencies: ["FrameEngine"], path: "tools/HDRProbe"),
        .executableTarget(name: "FrameBenchmark", dependencies: ["FrameEngine", "CFrameEngine", .product(name: "DLSSMedia", package: "MLX-DLSS")], path: "tools/FrameBenchmark"),
        .executableTarget(name: "HDRPlayer", dependencies: ["CMpv"],
                          path: "apps/macos/Sources", resources: [.copy("Resources/Controls")]),
        .executableTarget(name: "HDRHarness", dependencies: ["FrameEngine", .product(name: "DLSSMedia", package: "MLX-DLSS"), .product(name: "DLSSMLX", package: "MLX-DLSS")],
                          path: "apps/harness/Sources", resources: [.copy("Resources/Controls")]),
        .testTarget(name: "FrameEngineTests", dependencies: ["FrameEngine"], path: "packages/FrameEngine/Tests"),
    ]
)
