import Foundation
import MLXQwenLLM
import MLXServeCore
import MLXToolKit
import PromptEnhanceKit
import PromptEnhancePlugin
import Tokenizers

// The in-process reference for the helper: one profile's rewrite, on the backbone the plugin runs it on, through
// MLXServeEngine in this process, with the plugin's sampling. Prints one JSON line: the text, the outcome, timings and
// the tokens. Not part of the plugin bundle.
//
//   prompt-inproc --profile <id> --prompt <text> [--mode always|auto] [--temperature 0] [--seed 42]
//                 [--width W --height H] [--models-root <dir>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
guard let id = option("--profile"), let profile = library.profile(id: id), let prompt = option("--prompt") else {
    FileHandle.standardError.write(Data("usage: prompt-inproc --profile <id> --prompt <text> [options]\n".utf8))
    exit(2)
}
let mode: EnhanceMode = option("--mode") == "auto" ? .auto : .always
let temperature = Double(option("--temperature") ?? "") ?? 0
let seed = UInt64(option("--seed") ?? "") ?? 42
let target = option("--width").flatMap(Int.init).flatMap { w in option("--height").flatMap(Int.init).map { (width: w, height: $0) } }
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
let backbone = Backbone.serving(profile)

let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let package = PackageID(backbone.rawValue)
_ = try await engine.register(QwenLLMPackage.registration, configuration: backbone.configuration, id: package)
var clock = ContinuousClock.now
_ = try await engine.prepare(.llm, package: package)
let prepare = seconds(since: clock)

// mlx-qwen-llm-swift reports no usage, so each answer's tokens are counted with the model's tokenizer and timed per
// engine call: tokens per second over whole calls, prefill included.
var answers: [String] = [], calls = 0.0
clock = ContinuousClock.now
let enhancer = PromptEnhancer(parameters: parameters(temperature: temperature, seed: seed))
let result = try await enhancer.enhance(prompt, profile: profile, task: .textToImage, mode: mode, targetSize: target) { request in
    let call = ContinuousClock.now
    let response = try await engine.run(request, package: package) as! LLMResponse
    calls += seconds(since: call)
    answers.append(response.text)
    return response.text
}
let run = seconds(since: clock)
var generated = 0
if let repo = backbone.model.weightsRepo, let folder = ModelStore(root: modelsRoot).directory(for: repo),
   let tokenizer = try? await AutoTokenizer.from(modelFolder: folder) {
    generated = answers.reduce(0) { $0 + tokenizer.encode(text: $1, addSpecialTokens: false).count }
}
let decode = calls

var out: [String: Any] = ["profile": id, "backbone": backbone.rawValue, "outcome": result.outcome.rawValue,
                          "attempts": result.attempts, "prompt": result.prompt, "prepare_s": prepare, "run_s": run,
                          "cold_s": seconds(since: started), "generated_tokens": generated, "decode_seconds": decode]
if decode > 0 { out["tokens_per_second"] = Double(generated) / decode }
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
