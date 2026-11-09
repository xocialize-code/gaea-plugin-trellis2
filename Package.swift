// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-trellis2: Microsoft's TRELLIS.2 (MIT; its DINOv3 conditioner is under the DINOv3 License, "Built with
// DINOv3") as a Gaea plugin on MES Mesh 0.1's mesh.generate: one image to a textured GLB, at three resolutions, each its
// own model with the memory it takes. One worker executable built on GaeaPluginKit over mlx-trellis2-swift, with
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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.12.0"),
        .package(url: "https://github.com/xocialize/mlx-trellis2-swift.git", from: "0.12.0"),
        .package(url: "https://github.com/xocialize/mlx-birefnet-swift.git", from: "0.4.0"),
        // Exactly the engine Gaea 1.4.0, GaeaPluginKit 0.12.0 and mlx-trellis2-swift 0.12.0's measurements are on: 0.76 adds
        // fields to the worker's memory report that GPP v1's closed schema doesn't carry.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", exact: "0.74.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.74.1 takes it: 0.32.4 is upstream 0.32.3 plus the
        // _updateInternal leak fix (ml-explore/mlx-swift#501; AB-D-0208). A root line naming ml-explore's URL would win.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.32.4"),
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
