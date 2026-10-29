import GaeaPluginKit
import PromptEnhancePlugin

// The plugin's worker: PromptEnhancePlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(promptEnhancePlugin)
