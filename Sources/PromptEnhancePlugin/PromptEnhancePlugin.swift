import Foundation
import GaeaPluginKit
import Synchronization
import GaeaProtocol
import MLXQwenLLM
import MLXToolKit
import PromptEnhanceKit

// gaea-plugin-prompt-enhance: the LLM plugin (Gaea G-10, AB-T-0370). prompt-enhance-kit's image-model profiles rewrite a
// short prompt into the caption a model was trained on, on Qwen3.5: the 4B for the prose profiles, the 9B for the
// structured ones (SenseNova's Render JSON, MOSS-Image's layouts), as pixel-agency-image-engine runs them
// (PromptBackbones, KitPromptEnhancer).
//
// The profiles stay here. The manifest lists the facts Gaea needs to decide whether a prompt needs the model at all
// (GPP-1 §4.4); the instructions, the compilers and the rewrite are the kit's, in this process. Gaea calls the helper
// `x-gaea.prompt.enhance` only when its decision says a rewrite is due.

public let enhanceOperation = "x-gaea.prompt.enhance"

/// The two backbones, by the ids the image normalizer and pixel-agency-image-engine use.
public enum Backbone: String, CaseIterable, Sendable {
    case small = "qwen3.5-4b"
    case large = "qwen3.5-9b"

    public var model: QwenModel { QwenModel(size: self == .small ? .b4 : .b9, quant: .int4) }
    public var configuration: QwenLLMConfiguration { QwenLLMConfiguration(model: model) }
    public var title: String { self == .small ? "Qwen3.5 4B" : "Qwen3.5 9B" }

    public static func serving(_ profile: EnhanceProfile) -> Backbone { profile.backbone == .large ? .large : .small }
}

/// prompt-enhance-kit's image-model profiles.
public let library = ProfileLibrary.imageModels()

/// The sampling a rewrite runs with: pixel-agency-image-engine's (temperature 0.7, 512 tokens), or greedy at
/// `temperature` 0.
public func parameters(temperature: Double, seed: UInt64) -> LLMParameters {
    LLMParameters(temperature: temperature, maxTokens: 512, seed: seed)
}

/// The task names Gaea and the image normalizer use (`PromptTask`), for the kit's tasks they share.
public let taskNames: [EnhanceTask: String] = [.textToImage: "textToImage", .imageEdit: "imageEdit"]

/// What a profile's decision reads, for the manifest.
func facts(_ profile: EnhanceProfile) -> PluginManifest.PromptProfile {
    let structured: Bool = if case .json = profile.output { true } else { false }
    let policy: PluginManifest.PromptProfile.Policy = switch profile.policy {
    case .required: .required
    case .recommended: .recommended
    case .optional: .optional
    }
    return PluginManifest.PromptProfile(
        id: profile.id, version: profile.version, title: profile.title, models: profile.models, policy: policy,
        tasks: profile.instructions.keys.compactMap { taskNames[$0] }.sorted(), structured: structured,
        suggestsSize: !profile.sizeFields.isEmpty, laysOutCanvas: profile.laysOutCanvas, large: profile.backbone == .large,
        passThroughStructured: profile.passThrough.structured, detailedAtWords: profile.passThrough.detailedAtWords)
}

/// The helper: the prompt (a text input) rewritten with `profile` for `task`, `mode` `auto` or `always`, as the kit's
/// enhancer does it, its answers coming from this model. Values out: `prompt`, `outcome`, `attempts`, and `failure`,
/// `suggested_size`, `canvas` when they apply.
let enhance = EngineOperation(enhanceOperation) { job, session in
    guard let id = job.param("profile")?.stringValue, let profile = library.profile(id: id) else {
        throw GPPError(.invalidRequest, "\(enhanceOperation) needs a profile: one of \(library.profiles.map(\.id).joined(separator: ", ")).")
    }
    let prompt = try job.text("prompt") ?? ""
    let task: EnhanceTask = job.param("task")?.stringValue == "imageEdit" ? .imageEdit : .textToImage
    let mode: EnhanceMode = job.param("mode")?.stringValue == "always" ? .always : .auto
    let size = job.param("target_size")
    let target = size.flatMap { s in s["width"]?.intValue.flatMap { w in s["height"]?.intValue.map { (width: w, height: $0) } } }
    let temperature = job.param("temperature")?.doubleValue ?? 0.7
    let timeout = job.param("timeout_s")?.doubleValue.map { Duration.milliseconds(Int64($0 * 1000)) }
    let enhancer = PromptEnhancer(parameters: parameters(temperature: temperature, seed: job.seed ?? 0))
    let usage = Usage()
    let result = try await enhancer.enhance(prompt, profile: profile, task: task, mode: mode, targetSize: target, timeout: timeout) {
        request in
        guard let response = try await session.run(request) as? LLMResponse else {
            throw GPPError(.modelError, "The backbone answered with something other than text.")
        }
        usage.add(response.usage)
        return response.text
    }
    var outputs: [Output] = [
        .value("prompt", .string(result.prompt)), .value("outcome", .string(result.outcome.rawValue)),
        .value("attempts", .int(Int64(result.attempts))),
    ]
    if let failure = result.failure { outputs.append(.value("failure", .string(failure))) }
    if let s = result.suggestedSize {
        var size: [String: JSONValue] = [:]
        if let w = s.width { size["width"] = .int(Int64(w)) }
        if let h = s.height { size["height"] = .int(Int64(h)) }
        if let a = s.aspectRatio { size["aspect_ratio"] = .string(a) }
        outputs.append(.value("suggested_size", .object(size)))
    }
    if let c = result.canvas { outputs.append(.value("canvas", ["width": .int(Int64(c.width)), "height": .int(Int64(c.height))])) }
    var effective: [String: JSONValue] = ["profile": .string(profile.id), "mode": .string(mode == .always ? "always" : "auto"),
                                          "temperature": .double(temperature)]
    effective.merge(usage.effective) { a, _ in a }
    return RunResult(outputs: outputs, effective: effective)
}

/// The tokens a rewrite's answers took, across its attempts: what tokens per second are measured from.
final class Usage: Sendable {
    private let totals = Mutex((prompt: 0, generated: 0, prefill: 0.0, decode: 0.0))

    func add(_ usage: LLMUsage?) {
        guard let usage else { return }
        totals.withLock {
            $0.prompt += usage.promptTokens; $0.generated += usage.generationTokens
            $0.prefill += usage.promptSeconds; $0.decode += usage.generateSeconds
        }
    }

    var effective: [String: JSONValue] {
        totals.withLock { t in
            guard t.generated > 0 else { return [:] }
            return ["prompt_tokens": .int(Int64(t.prompt)), "generated_tokens": .int(Int64(t.generated)),
                    "prefill_seconds": .double(t.prefill), "decode_seconds": .double(t.decode)]
        }
    }
}

let params: JSONValue = [
    "type": "object", "additionalProperties": false,
    "properties": [
        "profile": ["type": "string", "enum": .array(library.profiles.map { .string($0.id) }),
                    "description": "The profile to rewrite with."],
        "task": ["type": "string", "enum": ["textToImage", "imageEdit"], "default": "textToImage"],
        "mode": ["type": "string", "enum": ["auto", "always"], "default": "auto",
                 "description": "auto follows the profile's policy; always rewrites unless the prompt can't be."],
        "target_size": ["type": "object", "properties": ["width": ["type": "integer"], "height": ["type": "integer"]]],
        "temperature": ["type": "number", "minimum": 0, "maximum": 2, "default": 0.7,
                        "description": "0 is greedy: the same prompt gives the same text."],
        "timeout_s": ["type": "number", "minimum": 1],
    ],
    "required": ["profile"],
]

public let promptEnhancePlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.prompt-enhance",
    version: "0.1.0",
    minGaea: "0.5.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-prompt-enhance",
    title: "Prompt enhancer",
    summary: "Rewrites short prompts into the captions image models are trained on, with each model's own profile "
        + "(prompt-enhance-kit), on Qwen3.5 4B and 9B (Apache-2.0). Gaea calls it before an image model runs (prompt_enhance).",
    license: "Apache-2.0",
    executable: "gaea-prompt-enhance-worker",
    models: Backbone.allCases.map { backbone in
        .engine(QwenLLMPackage.self, id: backbone.rawValue, title: backbone.title,
                lanes: [LaneDefinition(id: Quant.int4.rawValue, default: true, configuration: backbone.configuration)],
                operations: [enhance])
    },
    offers: [],
    helpers: Backbone.allCases.map { backbone in
        PluginManifest.Helper(operation: enhanceOperation, model: backbone.rawValue, title: "Prompt enhancement",
                              summary: "\(backbone.title) rewrites prompts for the profiles listed.", params: params,
                              profiles: library.profiles.filter { Backbone.serving($0) == backbone }.map(facts))
    })
