# gaea-plugin-trellis2

Microsoft's **TRELLIS.2 4B** (MIT) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: a textured 3D mesh of the
object in one picture, on MES Mesh 0.1's `mesh.generate`. It is built on
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

Three models on `mesh.generate`, one per TRELLIS.2 resolution, because each takes its own memory:

| Model | Quality | Time on an M5 Max | Charged |
|---|---|---|---|
| `trellis2-512` (the default) | draft, standard | about a minute | 38 GB |
| `trellis2-1024` | best | 8 to 9 minutes | 69 GB |
| `trellis2-1536` | for `resolution: 1536`, or by name | 7 to 11 minutes | 72 GB |

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
- **`seed`**: the same seed and picture give the same GLB, byte for byte, on the same Mac and build (`deterministic:
  true`; AB-R-0814).
- **The result** is a GLB, +Y up, the object's front facing +Z. TRELLIS.2 makes objects in its own front-facing frame,
  so a three-quarter photo still comes out facing +Z. Gaea centres it (or stands it on the ground with
  `placement: grounded`), scales it to `size_m` (1 m by default), marks it AI-generated, and renders the preview.

## Lanes and memory

Each model has one lane, `bf16`: TRELLIS.2 pinned to its tier (`Trellis2Configuration.lane`), so a lane never runs above
the memory it is charged. BiRefNet is a companion model (`birefnet`, GaeaPluginKit 0.12.0): preparing any TRELLIS.2
model downloads and loads it too, and its memory is inside each tier's charge.

## Weights

Gaea sends its models root in `configure`. TRELLIS.2 reads `xocialize/trellis2-mlx` (about 15 GB, every component
including DINOv3 and its licence) and BiRefNet `mlx-community/BiRefNet-fp16` there, in MLXEngine's store layout. Both
are downloaded on first use when missing; `gaea plugins warm com.xocialize.gaea.trellis2 trellis2-512` does it ahead.

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
GLB, byte for byte, with the texture asked for: the fox with its background removed, already cut out
(`fox-cutout.png`, `scripts/fixtures-src/cutout.swift`) and kept whole, and another seed. `FULL=1` adds 1024 and 1536.
The fox photo was made with FLUX.2 Klein.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). TRELLIS.2 is MIT (Microsoft), and so is the port, mlx-trellis2-swift. Its DINOv3
conditioner is under Meta's [DINOv3 License](https://ai.meta.com/resources/models-and-libraries/dinov3-license/)
("Built with DINOv3"). BiRefNet is MIT.
