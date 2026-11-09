import GaeaPluginKit
import Trellis2Plugin

// The plugin's worker: Trellis2Plugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(trellis2Plugin)
