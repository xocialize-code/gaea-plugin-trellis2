# gaea-plugin-trellis2

Microsoft's **TRELLIS.2 4B** (MIT) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: a textured 3D mesh of the
object in one picture, on MES Mesh 0.1's `mesh.generate`. From 0.2.0 it also carries **Pixal3D**, which follows the
photo pixel for pixel. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-trellis2-swift](https://github.com/xocialize/mlx-trellis2-swift), with
[mlx-birefnet-swift](https://github.com/xocialize/mlx-birefnet-swift) cutting the object out of an opaque picture. It runs
in its own process and speaks the Gaea Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-trellis2
```

**Built with DINOv3.** TRELLIS.2's image conditioner is Meta's DINOv3, under the DINOv3 License, which asks for those
words wherever it ships. The offers carry them as the licence's `attribution`; Gaea writes them into every mesh
(`asset.copyright`, `asset.extras.mes.attribution`) and preview, and MES clients show them.

## What it offers

Five models on `mesh.generate`. TRELLIS.2 has one per resolution, because each takes its own memory, and Pixal3D
(0.2.0) has one per cascade resolution:

| Model | Runs for | Time on an M5 Max | Charged |
|---|---|---|---|
| `trellis2-512` (the default) | draft, standard | about a minute | 38 GB |
| `trellis2-1024` | best | 8 to 9 minutes | 69 GB |
| `trellis2-1536` | `resolution: 1536`, or by name | 7 to 11 minutes | 72 GB |
| `pixal3d-1024` | by name | 2 to 4 minutes | 71.3 GB, or 60.3 GB on its `bf16-lowmem` lane |
| `pixal3d-1536` | by name | 8 to 10 minutes | 76.2 GB, or 65.2 GB on its `bf16-lowmem` lane |

**Pixal3D** (Tencent ARC, MIT) runs on TRELLIS.2's decoders with its own flows, and follows the photo pixel for pixel
through a camera. Stock TRELLIS.2 invents what it can't tell from the picture; on thin and layered subjects (a dress, hair)
Pixal3D keeps the shape the photo shows (mlx-trellis2-swift's README, "Pixal3D mode", has the measurements).
- **The camera.** `x-pixal3d.fov` is the photo's horizontal field of view in degrees, 20 by default. That suits a studio
  product shot. Give a phone or wide-lens photo its own, for example from its EXIF focal length: nothing here
  estimates it.
- **The view.** The mesh comes back as the photo saw it: +Y is the photo's up and the camera is on +Z. A shot taken
  from above comes out tilted by the camera's elevation.
- **No 512.** Pixal3D runs at 1024 and 1536 only.
- **By name.** Its offers are named-only, so a request runs Pixal3D only by naming it.

The memory is mlx-trellis2-swift's per-tier bound (AB-R-0811: peaks of 30.5, 60.7 and 65.2 GB with BiRefNet in the same
process; AB-R-0814: a 2048 texture takes res512 to 34.7 GB, so its lane is charged 38 GB). Gaea offers only the models its budget can hold, and an operator who wants only quick meshes (a preview server)
turns the others off:

```bash
gaea models disable trellis2-1024
```

```bash
gaea models disable trellis2-1536
```

- **The picture.** An opaque picture is cut out with BiRefNet first (`supports.background_removal`); a picture with
  transparency is used as it is cut out; `background: keep` uses the whole frame.
- **`max_faces`** 1,000 to 2,000,000 (300,000 by default): the mesh is decimated to it.
- **`texture_size`** 512, 1024 or 2048 on `trellis2-512`, and 4096 too on the cascades (1024 by default): the atlas. A
  4096 atlas would cost the 512 tier another 10 GB, while the cascades' peaks don't move. The mesh is UV-textured
  (`texture: atlas`) with a base-colour and a metallic-roughness map.
- **Detail maps** (0.2.0), as MES extensions on every model, off by default:
  - `x-trellis2.normal_map` adds a tangent-space normal map (with `TANGENT`), baked from the full-resolution surface. It
    gives back the fine relief a mesh loses when it is cut down to `max_faces`.
  - `x-trellis2.ao_map` adds an ambient-occlusion map. It shares the metallic-roughness texture (glTF ORM).
  - Both are at the texture's size. At 1024 they cost under a second, and at 4096 about 10 s.
- **Valid normals** (0.2.0). Every normal is unit length, so the GLBs pass the Khronos glTF validator. Up to 0.1.0 a few
  vertices on zero-thickness fins were written with zero-length normals.
- **`seed`**: the same seed and picture give the same GLB, byte for byte, on the same Mac and build (`deterministic:
  true`; AB-R-0814).
- **The result** is a GLB, +Y up, the object's front facing +Z. TRELLIS.2 makes objects in its own front-facing frame,
  so a three-quarter photo still comes out facing +Z. Gaea centres it (or stands it on the ground with
  `placement: grounded`), scales it to `size_m` (1 m by default), marks it AI-generated, and renders the preview.

## Lanes and memory

Lanes are named for their stored weights, which are bf16 everywhere. Each TRELLIS.2 model has one lane, `bf16`: TRELLIS.2
pinned to its tier (`Trellis2Configuration.lane`), so a lane never runs above the memory it is charged.

Each Pixal3D model has two lanes that give the same GLB, byte for byte:
- `bf16`, the default: the flow weights are cast to fp32 when they load, as on TRELLIS.2's lanes.
- `bf16-lowmem`: they stay in bf16 and are converted inside each step. It holds 11 GB less and is 8 to 15 % slower
  (AB-R-0870).

Gaea loads `bf16` when it fits and falls back to `bf16-lowmem` when it doesn't, with a `lane_fallback` warning.
`gaea models lane pixal3d-1024 bf16-lowmem` makes the smaller lane the default.

BiRefNet is a companion model (`birefnet`): preparing any model downloads and loads it too. TRELLIS.2's charges were
measured with it loaded; Pixal3D's lanes add its 0.9 GB.

## Weights

Gaea sends its models root in `configure`. In MLXEngine's store layout there:
- TRELLIS.2 reads `xocialize/trellis2-mlx` (about 15 GB, every component including DINOv3 and its licence);
- Pixal3D reads that and `xocialize/pixal3d-mlx` (about 11 GB: four flows and the NAF upsampler);
- BiRefNet reads `mlx-community/BiRefNet-fp16`.

Each is downloaded on first use when missing; `gaea plugins warm com.xocialize.gaea.trellis2 pixal3d-1024` does it
ahead.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` makes a mesh of `Tests/Fixtures/fox.png` over GPP on the signed bundle, with every `.build` folder
hidden. It then shows that the bare worker, outside the bundle, finds no metallib.

`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
The release workflow does the same in CI when a `v<version>` tag is pushed.

`trellis2-inproc` (its header lists the options) is not part of the plugin. It runs the same packages in-process through
MLXServeEngine, with the worker's lane configurations, matting step and request: the reference Gaea's runs are compared
against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` makes meshes over GPP on the signed bundle and through `trellis2-inproc`, and needs each pair to be the same
GLB, byte for byte, with the texture asked for:
- TRELLIS.2 at 512: the fox with its background removed, already cut out (`fox-cutout.png`,
  `scripts/fixtures-src/cutout.swift`) and kept whole, another seed, and the detail maps;
- Pixal3D at 1024: both lanes (which must also equal each other) and another field of view.

`FULL=1` adds TRELLIS.2 at 1024 and 1536 and Pixal3D at 1536.
The fox photo was made with FLUX.2 Klein.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). TRELLIS.2 is MIT (Microsoft), and so is the port, mlx-trellis2-swift. Pixal3D's
code and weights are MIT (Tencent ARC), and its NAF upsampler is Apache-2.0 (valeo.ai). The DINOv3
conditioner both use is under Meta's [DINOv3 License](https://ai.meta.com/resources/models-and-libraries/dinov3-license/)
("Built with DINOv3"). BiRefNet is MIT.
