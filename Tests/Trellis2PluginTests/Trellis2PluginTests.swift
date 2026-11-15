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

    @Test func stockTiersKeepTheirOffersAndCharges() throws {
        let manifest = try trellis2Plugin.manifest()
        let stock = tiers.filter { !$0.pixal3d }
        #expect(stock.map(\.id) == ["trellis2-512", "trellis2-1024", "trellis2-1536"])
        for tier in stock {
            let model = try #require(manifest.models.first { $0.id == tier.id })
            #expect(model.lanes.map(\.id) == ["bf16"])
            let repos = model.lanes[0].resolved.weightSources.map(\.repo)
            #expect(repos.first == "xocialize/trellis2-mlx")
            #expect(repos.contains("mlx-community/BiRefNet-fp16"), "BiRefNet's weights too: \(repos)")
            #expect(!repos.contains("xocialize/pixal3d-mlx"))
            let offer = try #require(manifest.offers.first { $0.modelID == tier.id })
            #expect(offer.model["default"] == .bool(tier.isDefault) && offer.model["named_only"] == nil)
        }
        // Each lane is charged its tier's bound (AB-A-0262; 38 GB at 512 for textures up to 2048, AB-R-0814).
        let need = stock.map { tier in manifest.models.first { $0.id == tier.id }!.lanes[0].resolved }
            .map { $0.persistentBytes + $0.peakTransientBytes }
        #expect(need == [38_000_000_000, 69_000_000_000, 72_000_000_000])
    }

    @Test func pixal3dIsNamedOnlyWithTwoLanesAndItsOwnWeights() throws {
        let manifest = try trellis2Plugin.manifest()
        for (id, fp32, bf16) in [("pixal3d-1024", 70.4, 59.4), ("pixal3d-1536", 75.3, 64.3)] {
            let model = try #require(manifest.models.first { $0.id == id })
            #expect(model.lanes.map(\.id) == ["bf16", "bf16-lowmem"] && model.lanes[0].default && !model.lanes[1].default)
            #expect(model.lanes[0].resolved.weightSources.map(\.repo).contains("xocialize/pixal3d-mlx"))
            // The package's lane figures (AB-R-0869, AB-R-0870) plus BiRefNet's resident 0.9 GB, charged to the lane.
            let need = model.lanes.map { Double($0.resolved.persistentBytes + $0.resolved.peakTransientBytes) / 1e9 }
            #expect(abs(need[0] - (fp32 + 0.9)) < 0.11 && abs(need[1] - (bf16 + 0.9)) < 0.11, "\(id): \(need)")
            let offer = try #require(manifest.offers.first { $0.modelID == id })
            #expect(offer.model["named_only"] == true && offer.model["default"] == nil)
            #expect(offer.params?["properties"]?["x-pixal3d.fov"]?["default"]?.doubleValue == 20)
        }
        #expect(manifest.offers.allSatisfy { $0.params?["properties"]?["x-trellis2.normal_map"] != nil })
        #expect(manifest.offers.filter { $0.params?["properties"]?["x-pixal3d.fov"] != nil }.count == 2)
    }

    @Test func mapsAndTheCameraReachTheRequestOnlyWhenAsked() throws {
        let plain = request(image: .init(format: .png, data: Data()), tier: tiers[0], ask: try ask(job([:]), tier: tiers[0]))
        #expect(Set(plain.metaData.keys) == ["seed", "decimateFaces", "texture", "atlasSize", "yUp", "pbrMaps"] && plain.cameras == nil)
        let pixal = try #require(tiers.first { $0.id == "pixal3d-1024" })
        let a = try ask(job(["x-trellis2.normal_map": true, "x-trellis2.ao_map": true, "x-pixal3d.fov": 49]), tier: pixal)
        let r = request(image: .init(format: .png, data: Data()), tier: pixal, ask: a)
        #expect(r.metaData["normalMap"] == .bool(true) && r.metaData["aoMap"] == .bool(true))
        #expect(r.cameras == [ImageTo3DCamera(fovXDegrees: 49)] && r.mode == pixal.mode)
        #expect(a.effective["x-pixal3d.fov"]?.doubleValue == 49 && a.effective["x-trellis2.normal_map"] == true)
        #expect(try ask(job([:]), tier: pixal).fov == 20)
        #expect(throws: GPPError.self) { try ask(self.job(["x-pixal3d.fov": 150]), tier: pixal) }
        // Stock TRELLIS.2 takes no camera.
        #expect(try ask(job(["x-pixal3d.fov": 49]), tier: tiers[0]).fov == nil)
    }

    @Test func anOpaqueMatteIsTheImagesSize() throws {
        let matte = try MattingStep.opaque(Image(format: .png, data: Data(), width: 7, height: 5))
        #expect(matte.width == 7 && matte.height == 5 && matte.kind == .softAlpha)
    }
}
