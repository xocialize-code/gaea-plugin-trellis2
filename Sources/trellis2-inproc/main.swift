import Foundation
import GaeaProtocol
import MLXBiRefNet
import MLXServeCore
import MLXToolKit
import Trellis2Kit
import Trellis2Plugin

// The in-process reference for the plugin: TRELLIS.2 and BiRefNet loaded by MLXServeEngine in this process, with the
// lane configurations and the request the worker builds (Trellis2Plugin), and BiRefNet as the matting step. The GLB is
// written to --out, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   trellis2-inproc --image <png|jpg> [--tier 512|1024|1536] [--seed 0] [--faces 300000] [--texture-size 1024]
//                   [--background remove|keep|alpha] [--models-root <dir>] [--out <glb>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard let imagePath = option("--image") else { fatalError("trellis2-inproc needs --image") }
let resolution = Int(option("--tier") ?? "") ?? 512
guard let tier = tiers.first(where: { $0.resolution == resolution }) else { fatalError("no tier \(resolution)") }
let ask = Ask(seed: UInt64(option("--seed") ?? "") ?? 0, faces: Int(option("--faces") ?? "") ?? defaultFaces,
              textureSize: Int(option("--texture-size") ?? "") ?? defaultTextureSize, background: option("--background") ?? "remove")

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 100_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let matteID = PackageID(birefnetID), id = PackageID(tier.id)
_ = try await engine.register(BiRefNetPackage.registration, configuration: birefnetConfiguration(), id: matteID)
_ = try await engine.register(Trellis2Package.registration, configuration: configuration(tier), id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.matting, package: matteID)
_ = try await engine.prepare(.imageTo3D, package: id)
var result: [String: Any] = ["model": tier.id, "seed": ask.seed, "faces": ask.faces, "texture_size": ask.textureSize,
                             "background": ask.background, "prepare_s": seconds(since: clock)]
clock = ContinuousClock.now
let url = URL(fileURLWithPath: imagePath)
let data = try Data(contentsOf: url)
let picture = Image(format: url.pathExtension.lowercased() == "png" ? .png : .jpeg, data: data)
let step: @Sendable (Image) async throws -> Matte = ask.background == "keep" ? { try MattingStep.opaque($0) } : { frame in
    guard let response = try await engine.run(MattingRequest(image: frame), package: matteID) as? MattingResponse else {
        fatalError("BiRefNet returned no matte")
    }
    return response.matte
}
let response = try await MattingStep.with(step) { try await engine.run(request(image: picture, tier: tier, ask: ask), package: id) }
guard let mesh = (response as? ImageTo3DResponse)?.mesh else { fatalError("TRELLIS.2 returned no mesh") }
result["run_s"] = seconds(since: clock)
result["faces_made"] = mesh.faceCount ?? 0
result["vertices"] = mesh.vertexCount ?? 0
if let out = option("--out") { try mesh.data.write(to: URL(fileURLWithPath: out)) }
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
