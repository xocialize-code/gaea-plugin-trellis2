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
// - Pixal3D (0.2.0; Tencent ARC, MIT, on TRELLIS.2's decoders): two more models, pixal3d-1024 and pixal3d-1536, that
//   follow the photo pixel for pixel through its camera (`x-pixal3d.fov`, 20° by default). They fix what stock
//   TRELLIS.2 invents on thin and layered subjects, and come back in the photo's own view. Named-only until an operator
//   has looked at them. Each has two lanes: `bf16` (71.3 / 76.2 GB) and `bf16-lowmem`, the same bytes from flows kept
//   in bf16 (60.3 / 65.2 GB, 8 to 15 % slower), which Gaea falls back to when the first doesn't fit.
// - Detail maps (0.2.0): `x-trellis2.normal_map` and `x-trellis2.ao_map` add a tangent-space normal map and an
//   ambient-occlusion map at the texture's size, on every model. Off by default.
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
    /// A Pixal3D model: `Pixal3DPackage` on a Pixal3D lane, with a camera, offered by name only.
    public var pixal3d = false

    /// The lanes, default first, each named for its stored weights (bf16), as the manifest's rules ask. `bf16` casts the
    /// flows to fp32 when they load; Pixal3D's `bf16-lowmem` keeps them in bf16.
    public var lanes: [String] { pixal3d ? ["bf16", lowMemoryLane] : ["bf16"] }
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
    Tier(id: "pixal3d-1024", title: "Pixal3D 1024", mode: ImageTo3DContract.res1024, resolution: 1024, qualityTiers: ["best"],
         textureSizes: [512, 1024, 2048, 4096],
         notes: "Pixal3D on TRELLIS.2's 1024 cascade: the mesh follows the photo pixel for pixel through its camera, so thin and "
             + "layered subjects keep their shape, and it comes back in the photo's view. 2 to 4 minutes; 71 GB, or 60 GB on its bf16-lowmem lane.",
         isDefault: false, pixal3d: true),
    Tier(id: "pixal3d-1536", title: "Pixal3D 1536", mode: ImageTo3DContract.res1536, resolution: 1536, qualityTiers: ["best"],
         textureSizes: [512, 1024, 2048, 4096],
         notes: "Pixal3D on the 1536 cascade, the most detail: about 8 to 10 minutes; 76 GB, or 65 GB on its bf16-lowmem lane.",
         isDefault: false, pixal3d: true),
]

/// Pixal3D's second lane: the same GLB bytes from flows kept in bf16, 11 GB less and 8 to 15 % slower (AB-R-0870).
public let lowMemoryLane = "bf16-lowmem"

/// Pixal3D's horizontal field of view when the request doesn't say: the package's default, proven on matted product
/// shots (AB-R-0865). A phone or wide-lens photo wants its own, for example from EXIF.
public let defaultFOV = 20.0
/// The range Pixal3D declares and is tested on (`Pixal3DPackage.controls`).
public let fovRange = 1.0...119.0

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

/// A tier's lane: TRELLIS.2 or Pixal3D pinned to it (its footprint is the tier's bound, AB-A-0262), with the matting
/// hook. Pixal3D's `bf16-lowmem` lane keeps the flow weights in bf16: the same GLB bytes for 11 GB less (AB-R-0870).
public func configuration(_ tier: Tier, lane: String? = nil) -> Trellis2Configuration {
    let atlas = tier.textureSizes.max() ?? defaultTextureSize
    var configuration = tier.pixal3d ? Trellis2Configuration.pixal3dLane(tier.mode, maxAtlasSize: atlas)
                                     : Trellis2Configuration.lane(tier.mode, maxAtlasSize: atlas)
    if tier.pixal3d, lane == lowMemoryLane { configuration.flowWeightsBF16 = true }
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
    /// `x-trellis2.normal_map` and `x-trellis2.ao_map`: the detail maps, at the texture's size.
    public var normalMap = false
    public var aoMap = false
    /// `x-pixal3d.fov`: the photo's horizontal field of view in degrees. Nil on stock TRELLIS.2, which takes no camera.
    public var fov: Double?

    public init(seed: UInt64, faces: Int, textureSize: Int, background: String, normalMap: Bool = false, aoMap: Bool = false,
                fov: Double? = nil) {
        self.seed = seed; self.faces = faces; self.textureSize = textureSize; self.background = background
        self.normalMap = normalMap; self.aoMap = aoMap; self.fov = fov
    }

    public var effective: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "seed": .int(Int64(seed)), "max_faces": .int(Int64(faces)), "texture": "atlas", "texture_size": .int(Int64(textureSize)),
            "background": .string(background),
        ]
        if normalMap { values["x-trellis2.normal_map"] = true }
        if aoMap { values["x-trellis2.ao_map"] = true }
        if let fov { values["x-pixal3d.fov"] = .double(fov) }
        return values
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
    var fov: Double?
    if tier.pixal3d {
        fov = job.param("x-pixal3d.fov")?.doubleValue ?? defaultFOV
        guard let fov, fovRange.contains(fov) else {
            throw GPPError(.invalidRequest, "x-pixal3d.fov is the photo's horizontal field of view, 1 to 119 degrees.",
                           detail: ["param": "x-pixal3d.fov"])
        }
    }
    return Ask(seed: job.seed ?? 0, faces: faces, textureSize: size, background: background,
               normalMap: job.param("x-trellis2.normal_map")?.boolValue ?? false,
               aoMap: job.param("x-trellis2.ao_map")?.boolValue ?? false, fov: fov)
}

/// The engine request for an image at a tier (mlx-trellis2-swift's per-request keys, AB-A-0263): +Y up, with the
/// metallic-roughness map, always; the detail maps when asked (0.17.0); and on Pixal3D the photo's camera as the
/// contract's typed field (1.64.0). A request without the new options has the keys 0.1.0 sent, and no others.
public func request(image: Image, tier: Tier, ask: Ask) -> ImageTo3DRequest {
    var metaData: MetaData = [
        "seed": .int(Int(ask.seed)), "decimateFaces": .int(ask.faces), "texture": .bool(true), "atlasSize": .int(ask.textureSize),
        "yUp": .bool(true), "pbrMaps": .bool(true),
    ]
    if ask.normalMap { metaData["normalMap"] = .bool(true) }
    if ask.aoMap { metaData["aoMap"] = .bool(true) }
    return ImageTo3DRequest(image: image, mode: tier.mode, cameras: ask.fov.map { [ImageTo3DCamera(fovXDegrees: $0)] },
                            metaData: metaData)
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
        guard let mesh = (response as? ImageTo3DResponse)?.mesh else { throw GPPError(.modelError, "\(tier.title) returned no mesh.") }
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

/// Pixal3D's flows and its NAF upsampler are permissive (AB-D-0229); it conditions on DINOv3 as TRELLIS.2 does.
public let pixal3dLicense: JSONValue = [
    "spdx": "LicenseRef-DINOv3", "commercial_use": true,
    "terms_url": "https://ai.meta.com/resources/models-and-libraries/dinov3-license/",
    "attribution": "Built with DINOv3",
    "notice": "Pixal3D (Tencent ARC) and TRELLIS.2 are MIT, and the NAF upsampler is Apache-2.0; the DINOv3 image conditioner is under Meta's DINOv3 License, which asks for \"Built with DINOv3\" wherever it ships.",
]

func model(_ tier: Tier) -> ModelDefinition {
    let lanes = tier.lanes.enumerated().map { i, id in
        LaneDefinition(id: id, default: i == 0, configuration: configuration(tier, lane: id))
    }
    guard tier.pixal3d else {
        // Stock TRELLIS.2's footprints were measured with BiRefNet loaded (AB-R-0811), so it isn't charged again.
        return ModelDefinition.engine(Trellis2Package.self, id: tier.id, title: tier.title, lanes: lanes, operations: [generate(tier)])
            .composing([birefnetID])
    }
    // Pixal3D's were measured on matted inputs, without it (AB-R-0869): its lanes carry BiRefNet's memory too.
    return ModelDefinition.engine(Pixal3DPackage.self, id: tier.id, title: tier.title, lanes: lanes, operations: [generate(tier)])
        .composing([birefnetID], charged: true)
}

let birefnet = ModelDefinition.engine(BiRefNetPackage.self, id: birefnetID, title: "BiRefNet (background removal for TRELLIS.2)",
                                      lanes: [LaneDefinition(id: "fp16", default: true, configuration: birefnetConfiguration())],
                                      operations: [])

/// The plugin's own options, as MES extensions (Base §6.2).
func params(_ tier: Tier) -> JSONValue {
    var properties: [String: JSONValue] = [
        "x-trellis2.normal_map": [
            "type": "boolean", "default": false,
            "description": "Also write a tangent-space normal map at the texture's size: the fine relief the mesh loses when it is cut down to max_faces.",
            "x-mes-ui": ["widget": "toggle", "label": "Normal map", "advanced": true]],
        "x-trellis2.ao_map": [
            "type": "boolean", "default": false,
            "description": "Also write an ambient-occlusion map at the texture's size.",
            "x-mes-ui": ["widget": "toggle", "label": "Ambient occlusion map", "advanced": true]],
    ]
    if tier.pixal3d {
        properties["x-pixal3d.fov"] = [
            "type": "number", "minimum": .double(fovRange.lowerBound), "maximum": .double(fovRange.upperBound), "default": .double(defaultFOV),
            "description": "The photo's horizontal field of view in degrees. 20 suits a studio product shot; give a phone or wide-lens photo its own (about 65 for a phone's main camera).",
            "x-mes-ui": ["widget": "slider", "label": "Field of view (°)", "advanced": true]]
    }
    return ["type": "object", "properties": .object(properties), "additionalProperties": false]
}

func offer(_ tier: Tier) -> PluginManifest.Offer {
    var model: [String: JSONValue] = [
            "id": .string(tier.id), "title": .string(tier.title), "license": tier.pixal3d ? pixal3dLicense : license,
            "memory_class": "xlarge", "speed_class": "slow", "quality_tiers": .array(tier.qualityTiers.map { .string($0) }),
            "notes": .string(tier.notes),
            "supports": [
                "seed": true, "background_removal": true, "resolutions": [.int(Int64(tier.resolution))], "textures": ["atlas"],
                "texture_sizes": .array(tier.textureSizes.map { .int(Int64($0)) }), "maps": ["base_color", "metallic_roughness"],
                "deterministic": true,
            ],
            "limits": ["min_faces": .int(Int64(minFaces)), "max_faces": .int(Int64(maxFaces)),
                       "max_texture_size": .int(Int64(tier.textureSizes.max()!))],
    ]
    // Stock TRELLIS.2 keeps the `default` member 0.1.0 wrote; Pixal3D runs only by name.
    if tier.pixal3d { model["named_only"] = true } else { model["default"] = .bool(tier.isDefault) }
    return PluginManifest.Offer(
        operation: "mesh.generate", profile: "mesh", model: .object(model), params: params(tier),
        defaults: ["max_faces": .int(Int64(defaultFaces)), "texture_size": .int(Int64(defaultTextureSize))])
}

public let trellis2Plugin = GaeaPluginDefinition(
    // On mlx-engine-swift 0.79.0 (contract 1.64.0, Pixal3D's cameras): Gaea 1.8.0 is the first on it.
    id: "com.xocialize.gaea.trellis2", version: "0.2.0", minGaea: "1.8.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-trellis2", title: "TRELLIS.2",
    summary: "Microsoft's TRELLIS.2: a textured 3D mesh (GLB) of the object in one picture (MES mesh.generate), at 512, 1024 or 1536; and Pixal3D, which follows the photo pixel for pixel. Built with DINOv3.",
    license: "Apache-2.0", executable: "gaea-trellis2-worker",
    models: tiers.map(model) + [birefnet], offers: tiers.map(offer))
