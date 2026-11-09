import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXBiRefNet
import MLXToolKit
import Synchronization
import Trellis2Kit
import UniformTypeIdentifiers

// gaea-plugin-trellis2: Microsoft's TRELLIS.2 4B (MIT; mlx-trellis2-swift, MIT) on MES Mesh 0.1's mesh.generate
// (media-engine-spec v0.11.0, Gaea AB-T-0467): one picture of an object to a textured GLB.
//
// - Three models, one per resolution, because each takes its own memory (AB-R-0811, measured on an M5 Max 128 GB with
//   BiRefNet in the same process; AB-R-0814 for textures past 1024): trellis2-512 is charged 38 GB (textures up to 2048)
//   and takes about a minute; trellis2-1024 69 GB and 8 to
//   9 minutes; trellis2-1536 72 GB and 7 to 11. 512 answers draft and standard, 1024 best; 1536 runs when a request asks
//   for `resolution: 1536` or names it. An operator who wants only quick meshes (a preview server) disables the other two
//   with `gaea models disable`.
// - Background removal: an opaque picture is cut out with BiRefNet first (a companion model of the plugin, prepared
//   with each TRELLIS model); a picture with transparency is used as it is cut out; `background: keep` uses the whole
//   frame. TRELLIS.2 does the cutting and cropping itself through its matting hook, which runs the job's BiRefNet call.
// - The GLB is +Y up at the model's scale; Gaea places it, writes the disclosure and licences into it, and renders the
//   preview (GPP-1 §3.3.4). Its DINOv3 conditioner's licence asks for "Built with DINOv3" wherever it ships: the offers
//   carry it as the licence's attribution, and Gaea writes it into every mesh and preview.

public let birefnetID = "birefnet"

/// One resolution tier, served by its own model.
public struct Tier: Sendable {
    public var id: String
    public var title: String
    public var mode: Mode
    public var resolution: Int
    public var qualityTiers: [String]
    /// The texture sizes it makes. A 4096 atlas costs res512 10 GB more (AB-R-0814), so 512 stops at 2048; the
    /// cascades' peaks don't move.
    public var textureSizes: [Int]
    public var notes: String
    public var isDefault: Bool
}

public let tiers: [Tier] = [
    Tier(id: "trellis2-512", title: "TRELLIS.2 512", mode: ImageTo3DContract.res512, resolution: 512, qualityTiers: ["draft", "standard"],
         textureSizes: [512, 1024, 2048],
         notes: "A textured mesh of the object in one picture, at TRELLIS.2's 512 grid: about a minute and 38 GB. Draft and standard quality; textures up to 2048.",
         isDefault: true),
    Tier(id: "trellis2-1024", title: "TRELLIS.2 1024", mode: ImageTo3DContract.res1024, resolution: 1024, qualityTiers: ["best"],
         textureSizes: [512, 1024, 2048, 4096],
         notes: "TRELLIS.2's 1024 cascade: finer shape and texture, 8 to 9 minutes and 69 GB. Best quality.", isDefault: false),
    Tier(id: "trellis2-1536", title: "TRELLIS.2 1536", mode: ImageTo3DContract.res1536, resolution: 1536, qualityTiers: ["best"],
         textureSizes: [512, 1024, 2048, 4096],
         notes: "TRELLIS.2's 1536 cascade, the most detail: 7 to 11 minutes and 72 GB. Runs for resolution 1536, or by name.",
         isDefault: false),
]

/// The faces a mesh gets when the request doesn't say (TRELLIS.2's own default), and the range a request may ask for.
public let defaultFaces = 300_000, minFaces = 1_000, maxFaces = 2_000_000
/// The texture atlas size used when the request doesn't say.
public let defaultTextureSize = 1024

// MARK: - The matting step

/// What a job's matting hook runs: BiRefNet through the job's engine session, or, for `background: keep`, nothing (an
/// opaque matte: the whole frame is the object). TRELLIS.2's configuration is fixed when its lane loads, so the hook
/// reads the running job's step from here; a worker runs one job at a time.
public enum MattingStep {
    static let current = Mutex<(@Sendable (Image) async throws -> Matte)?>(nil)

    /// Runs `body` with `step` as the hook's matting.
    public static func with<T: Sendable>(_ step: @escaping @Sendable (Image) async throws -> Matte,
                                         _ body: () async throws -> T) async throws -> T {
        current.withLock { $0 = step }
        defer { current.withLock { $0 = nil } }
        return try await body()
    }

    /// The hook every lane carries.
    static let hook: Trellis2Matting = { image in
        guard let step = current.withLock({ $0 }) else { return try opaque(image) }
        return try await step(image)
    }

    /// A matte with every pixel opaque, at the image's size: `background: keep`.
    public static func opaque(_ image: Image) throws -> Matte {
        let (w, h) = try size(image)
        let pixels = [UInt8](repeating: 255, count: w * h)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw GPPError(.internal, "Couldn't make an opaque matte.")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw GPPError(.internal, "Couldn't make an opaque matte.")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw GPPError(.internal, "Couldn't make an opaque matte.") }
        return Matte(format: .png, data: out as Data, width: w, height: h, kind: .softAlpha)
    }

    static func size(_ image: Image) throws -> (Int, Int) {
        if let w = image.width, let h = image.height { return (w, h) }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw GPPError(.invalidRequest, "The image can't be read.")
        }
        return (w, h)
    }
}

// MARK: - Lanes and requests

/// A tier's lane: TRELLIS.2 pinned to it (its footprint is the tier's bound, AB-A-0262), with the matting hook.
public func configuration(_ tier: Tier) -> Trellis2Configuration {
    var configuration = Trellis2Configuration.lane(tier.mode, maxAtlasSize: tier.textureSizes.max() ?? defaultTextureSize)
    configuration.matting = MattingStep.hook
    return configuration
}

/// BiRefNet as TRELLIS.2's demo and the receipt ran it: the general checkpoint at 1024, fp16.
public func birefnetConfiguration() -> BiRefNetConfiguration { BiRefNetConfiguration() }

/// What a mesh.generate job asks of TRELLIS.2, validated.
public struct Ask: Sendable, Equatable {
    public var seed: UInt64
    public var faces: Int
    public var textureSize: Int
    /// `alpha`, `remove` or `keep` (GPP-1 §3.3.4).
    public var background: String

    public init(seed: UInt64, faces: Int, textureSize: Int, background: String) {
        self.seed = seed; self.faces = faces; self.textureSize = textureSize; self.background = background
    }

    public var effective: [String: JSONValue] {
        ["seed": .int(Int64(seed)), "max_faces": .int(Int64(faces)), "texture": "atlas", "texture_size": .int(Int64(textureSize)),
         "background": .string(background)]
    }
}

public func ask(_ job: Job, tier: Tier) throws -> Ask {
    if let texture = job.param("texture")?.stringValue, texture != "atlas" {
        throw GPPError(.invalidRequest, "TRELLIS.2 writes a texture atlas, not vertex colours.", detail: ["param": "texture"])
    }
    let faces = job.param("max_faces")?.intValue ?? defaultFaces
    guard (minFaces...maxFaces).contains(faces) else {
        throw GPPError(.invalidRequest, "TRELLIS.2 makes \(minFaces) to \(maxFaces) faces.", detail: ["param": "max_faces"])
    }
    let size = job.param("texture_size")?.intValue ?? defaultTextureSize
    guard tier.textureSizes.contains(size) else {
        throw GPPError(.invalidRequest, "\(tier.title)'s texture is \(tier.textureSizes.map(String.init).joined(separator: ", ")) pixels.",
                       detail: ["param": "texture_size"])
    }
    let background = job.param("background")?.stringValue ?? "remove"
    guard ["alpha", "remove", "keep"].contains(background) else {
        throw GPPError(.invalidRequest, "background is alpha, remove or keep.", detail: ["param": "background"])
    }
    return Ask(seed: job.seed ?? 0, faces: faces, textureSize: size, background: background)
}

/// The engine request for an image at a tier (mlx-trellis2-swift 0.12.0's per-request keys, AB-A-0263): +Y up, with the
/// metallic-roughness map, always.
public func request(image: Image, tier: Tier, ask: Ask) -> ImageTo3DRequest {
    ImageTo3DRequest(image: image, mode: tier.mode, metaData: [
        "seed": .int(Int(ask.seed)), "decimateFaces": .int(ask.faces), "texture": .bool(true), "atlasSize": .int(ask.textureSize),
        "yUp": .bool(true), "pbrMaps": .bool(true),
    ])
}

/// Decodes a GPP image input (PNG or JPEG; Gaea converts anything else).
func image(_ url: URL) throws -> Image {
    let data = try Data(contentsOf: url)
    let format: Image.Format = url.pathExtension.lowercased() == "png" ? .png : .jpeg
    let size = try MattingStep.size(Image(format: format, data: data))
    return Image(format: format, data: data, width: size.0, height: size.1)
}

func generate(_ tier: Tier) -> EngineOperation {
    EngineOperation("mesh.generate") { job, session in
        guard let url = job.input("image") else {
            throw GPPError(.invalidRequest, "mesh.generate needs the image.", detail: ["param": "image"])
        }
        let ask = try ask(job, tier: tier)
        let picture = try image(url)
        // The hook runs inside this job's own engine call, on its session: one job at a time per worker.
        let matter = session
        let step: @Sendable (Image) async throws -> Matte
        if ask.background == "keep" {
            step = { try MattingStep.opaque($0) }
        } else {
            step = { frame in
                guard let response = try await matter.run(MattingRequest(image: frame), model: birefnetID) as? MattingResponse else {
                    throw GPPError(.modelError, "BiRefNet returned no matte.")
                }
                return response.matte
            }
        }
        let response = try await MattingStep.with(step) {
            try await session.run(request(image: picture, tier: tier, ask: ask))
        }
        guard let mesh = (response as? ImageTo3DResponse)?.mesh else { throw GPPError(.modelError, "TRELLIS.2 returned no mesh.") }
        let file = session.outputDir.appending(path: "mesh-0.glb")
        try mesh.data.write(to: file)
        var effective = ask.effective
        effective["resolution"] = .int(Int64(tier.resolution))
        return RunResult(outputs: [.file("mesh", file, mediaType: "model/gltf-binary")], effective: effective)
    }
}

// MARK: - The plugin

public let license: JSONValue = [
    "spdx": "LicenseRef-DINOv3", "commercial_use": true,
    "terms_url": "https://ai.meta.com/resources/models-and-libraries/dinov3-license/",
    "attribution": "Built with DINOv3",
    "notice": "TRELLIS.2 is MIT; its DINOv3 image conditioner is under Meta's DINOv3 License, which asks for \"Built with DINOv3\" wherever it ships.",
]

func model(_ tier: Tier) -> ModelDefinition {
    ModelDefinition.engine(Trellis2Package.self, id: tier.id, title: tier.title,
                           lanes: [LaneDefinition(id: "bf16", default: true, configuration: configuration(tier))],
                           operations: [generate(tier)])
        .composing([birefnetID])
}

let birefnet = ModelDefinition.engine(BiRefNetPackage.self, id: birefnetID, title: "BiRefNet (background removal for TRELLIS.2)",
                                      lanes: [LaneDefinition(id: "fp16", default: true, configuration: birefnetConfiguration())],
                                      operations: [])

func offer(_ tier: Tier) -> PluginManifest.Offer {
    PluginManifest.Offer(
        operation: "mesh.generate", profile: "mesh",
        model: [
            "id": .string(tier.id), "title": .string(tier.title), "license": license,
            "memory_class": "xlarge", "speed_class": "slow", "quality_tiers": .array(tier.qualityTiers.map { .string($0) }),
            "default": .bool(tier.isDefault), "notes": .string(tier.notes),
            "supports": [
                "seed": true, "background_removal": true, "resolutions": [.int(Int64(tier.resolution))], "textures": ["atlas"],
                "texture_sizes": .array(tier.textureSizes.map { .int(Int64($0)) }), "maps": ["base_color", "metallic_roughness"],
                "deterministic": true,
            ],
            "limits": ["min_faces": .int(Int64(minFaces)), "max_faces": .int(Int64(maxFaces)),
                       "max_texture_size": .int(Int64(tier.textureSizes.max()!))],
        ],
        defaults: ["max_faces": .int(Int64(defaultFaces)), "texture_size": .int(Int64(defaultTextureSize))])
}

public let trellis2Plugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.trellis2", version: "0.1.0", minGaea: "1.4.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-trellis2", title: "TRELLIS.2",
    summary: "Microsoft's TRELLIS.2: a textured 3D mesh (GLB) of the object in one picture (MES mesh.generate), at 512, 1024 or 1536. Built with DINOv3.",
    license: "Apache-2.0", executable: "gaea-trellis2-worker",
    models: tiers.map(model) + [birefnet], offers: tiers.map(offer))
