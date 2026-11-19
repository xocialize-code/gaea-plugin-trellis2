// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-trellis2: Microsoft's TRELLIS.2 (MIT; its DINOv3 conditioner is under the DINOv3 License, "Built with
// DINOv3") as a Gaea plugin on MES Mesh 0.1's mesh.generate: one image to a textured GLB, at three resolutions, each its
// own model with the memory it takes; and Pixal3D (Tencent ARC, MIT) on the two cascade resolutions. One worker executable built on GaeaPluginKit over mlx-trellis2-swift, with
// BiRefNet (mlx-birefnet-swift) for cutting the object out of an opaque picture; packaged as a signed .gaeaplugin by
// scripts/build-plugin.sh.
//
// trellis2-inproc is not part of the plugin: it runs the same packages in-process through MLXServeEngine, with the same
// dependency resolution, lane configurations and requests, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]
// mlx-trellis2-swift vends xatlas through C++ interop, so every target that imports it builds with it too.
let cxx: [SwiftSetting] = [.interoperabilityMode(.Cxx)]

let package = Package(
    name: "gaea-plugin-trellis2",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"), // 0.14.1 on: the manifest names the engine actually linked (MLXEngineRelease)
        .package(url: "https://github.com/xocialize/mlx-trellis2-swift.git", exact: "0.17.0"),
        .package(url: "https://github.com/xocialize/mlx-birefnet-swift.git", from: "0.4.0"),
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1 (contract 1.66.0, which only adds imageLocate
        // to the 1.65.0 Gaea 1.9 decodes). Pinned exactly: a later 0.x could add fields to the worker's memory report
        // that GPP v1's closed schema doesn't carry, or a contract Gaea can't decode.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", exact: "0.82.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). It
        // replaces the 0.32.4 leak-fix fork (AB-D-0208), whose fix upstream 0.33.0 carries. A root line naming
        // ml-explore's URL would win and drop the patch.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.33.1"),
    ],
    targets: [
        .target(
            name: "Trellis2Plugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "Trellis2Kit", package: "mlx-trellis2-swift"),
                .product(name: "MLXBiRefNet", package: "mlx-birefnet-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ],
            swiftSettings: cxx
        ),
        .executableTarget(
            name: "gaea-trellis2-worker",
            dependencies: [
                "Trellis2Plugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ],
            swiftSettings: cxx
        ),
        .executableTarget(
            name: "trellis2-inproc",
            dependencies: [
                "Trellis2Plugin",
                .product(name: "Trellis2Kit", package: "mlx-trellis2-swift"),
                .product(name: "MLXBiRefNet", package: "mlx-birefnet-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: cxx + [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "Trellis2PluginTests",
            dependencies: ["Trellis2Plugin", .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                           .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"), .product(name: "MLXToolKit", package: "mlx-engine-swift")],
            swiftSettings: cxx
        ),
    ]
)
