import Foundation
@testable import GaeaPluginKit
import MLXToolKit
import GaeaProtocol
import Testing
@testable import Trellis2Plugin

@Suite struct Trellis2PluginTests {
    func job(_ params: [String: JSONValue], seed: UInt64? = 7) -> Job {
        Job(requestID: "r", job: "job_1", operation: "mesh.generate", model: "trellis2-512", lane: "bf16", inputs: [:],
            params: params, modelParams: [:], adapters: [], seed: seed, outputDir: URL(fileURLWithPath: "/tmp"))
    }

    @Test func asksMapToTheRequest() throws {
        let a = try ask(job(["max_faces": 120_000, "texture_size": 2048, "background": "alpha"]), tier: tiers[0])
        #expect(a == Ask(seed: 7, faces: 120_000, textureSize: 2048, background: "alpha"))
        let defaults = try ask(job([:], seed: nil), tier: tiers[0])
        #expect(defaults == Ask(seed: 0, faces: defaultFaces, textureSize: defaultTextureSize, background: "remove"))
        let r = request(image: .init(format: .png, data: Data()), tier: tiers[1], ask: a)
        #expect(r.mode == tiers[1].mode)
        #expect(r.metaData["decimateFaces"] == .int(120_000) && r.metaData["atlasSize"] == .int(2048))
        #expect(r.metaData["seed"] == .int(7) && r.metaData["yUp"] == .bool(true) && r.metaData["pbrMaps"] == .bool(true))
    }

    @Test func refusals() {
        #expect(throws: GPPError.self) { try ask(job(["texture": "vertex_colors"]), tier: tiers[0]) }
        #expect(throws: GPPError.self) { try ask(job(["max_faces": 10]), tier: tiers[0]) }
        #expect(throws: GPPError.self) { try ask(job(["texture_size": 300]), tier: tiers[0]) }
        #expect(throws: GPPError.self) { try ask(job(["texture_size": 4096]), tier: tiers[0]) }
        #expect((try? ask(job(["texture_size": 4096]), tier: tiers[1]))?.textureSize == 4096)
        #expect(throws: GPPError.self) { try ask(job(["background": "blur"]), tier: tiers[0]) }
    }

    @Test func manifestHasThreeTiersAndBiRefNetsWeightsOnEachLane() throws {
        let manifest = try trellis2Plugin.manifest()
        #expect(manifest.offers.map(\.modelID) == ["trellis2-512", "trellis2-1024", "trellis2-1536"])
        #expect(manifest.offers.allSatisfy { $0.profile == "mesh" && $0.operation == "mesh.generate" })
        for tier in tiers {
            let model = try #require(manifest.models.first { $0.id == tier.id })
            let repos = model.lanes[0].resolved.weightSources.map(\.repo)
            #expect(repos.first == "xocialize/trellis2-mlx")
            #expect(repos.contains("mlx-community/BiRefNet-fp16"), "BiRefNet's weights too: \(repos)")
        }
        // Each lane is charged its tier's bound (AB-A-0262).
        let need = tiers.map { tier in manifest.models.first { $0.id == tier.id }!.lanes[0].resolved }
            .map { $0.persistentBytes + $0.peakTransientBytes }
        #expect(need == [38_000_000_000, 69_000_000_000, 72_000_000_000])
    }

    @Test func anOpaqueMatteIsTheImagesSize() throws {
        let matte = try MattingStep.opaque(Image(format: .png, data: Data(), width: 7, height: 5))
        #expect(matte.width == 7 && matte.height == 5 && matte.kind == .softAlpha)
    }
}
