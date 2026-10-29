// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-prompt-enhance: the LLM plugin (Gaea G-10, AB-T-0370). Qwen3.5 4B and 9B on mlx-qwen-llm-swift, behind
// prompt-enhance-kit's image-model profiles, served as Gaea's `x-gaea.prompt.enhance` helper. One worker executable on
// GaeaPluginKit, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// prompt-inproc is not part of the plugin: it runs the same rewrite in-process through MLXServeEngine, on this package's
// one dependency resolution, as the reference a rewrite over GPP is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-prompt-enhance",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize/gaea-plugin-kit.git", from: "0.3.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
        .package(url: "https://github.com/xocialize/mlx-qwen-llm-swift.git", from: "0.6.2"),
        .package(url: "https://github.com/xocialize/prompt-enhance-kit-swift.git", from: "0.7.0"),
        // prompt-inproc counts the answers' tokens with the model's own tokenizer (mlx-qwen-llm-swift reports no usage).
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "PromptEnhancePlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXQwenLLM", package: "mlx-qwen-llm-swift"),
                .product(name: "PromptEnhanceKit", package: "prompt-enhance-kit-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-prompt-enhance-worker",
            dependencies: [
                "PromptEnhancePlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "prompt-inproc",
            dependencies: [
                "PromptEnhancePlugin",
                .product(name: "MLXQwenLLM", package: "mlx-qwen-llm-swift"),
                .product(name: "PromptEnhanceKit", package: "prompt-enhance-kit-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
