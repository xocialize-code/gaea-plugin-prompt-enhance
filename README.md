# gaea-plugin-prompt-enhance

The LLM plugin for [Gaea](https://github.com/xocialize-code/gaea): prompt enhancement. It rewrites a short prompt into the
caption an image model was trained on, with that model's own profile from
[prompt-enhance-kit](https://github.com/xocialize/prompt-enhance-kit-swift), on Qwen3.5 (Apache-2.0) through
[mlx-qwen-llm-swift](https://github.com/xocialize/mlx-qwen-llm-swift). Add it by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-prompt-enhance
```

## What it does

- **Two backbones**, as pixel-agency-image-engine runs them: `qwen3.5-4b` (int4, about 2 GB) for the prose profiles,
  and `qwen3.5-9b` (int4, about 4.5 GB) for the structured ones.
- **One helper, `x-gaea.prompt.enhance`**, which Gaea calls and never offers to clients. It takes the prompt and
  `profile`, `task`, `mode` (`auto` or `always`), `target_size`, `temperature` (0 is greedy) and `timeout_s`, and
  answers `prompt`, `outcome` and `attempts`, plus `suggested_size` and `canvas` for a structured profile.
- **The profiles stay here.** The manifest lists only the facts their decision reads: the models each serves, its
  policy, its tasks, and when a prompt goes as typed (GPP-1 §4.4). Gaea reads those facts, decides whether a prompt
  needs the model at all, and calls the helper only when it does.

| Profile | Models | Policy | Backbone |
|---|---|---|---|
| `flux2-klein` | klein-4b, klein-4b-base | recommended (a prompt of 60+ words goes as typed) | 4B |
| `qwen-image` | qwen-image-flash | recommended (60+ words) | 4B |
| `z-image` | z-image-turbo, z-image | optional (rewritten only with `prompt_enhance: on`) | 4B |
| `mage-flow` | mage-flow, mage-flow-turbo | optional | 4B |
| `sensenova-u1.5` | the SenseNova U1.5 models | recommended; answers Render JSON | 9B |
| `moss-image` | moss-image-sft, moss-image-base | optional; answers a layout for a canvas | 9B |

In Gaea, the image normalizer runs the rewrite before the image model, and reports it in
`effective.model_params.prompt_enhancement`. `image.enhance_prompt` previews it without generating.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` rewrites a prompt with the Klein profile on the 4B over GPP, greedy, with every `.build` folder
hidden. A control then shows that the bare worker, outside the bundle, can't find MLX's metallib.

```bash
swift build -c release --product prompt-inproc && scripts/golden.sh <out-dir>
```

`golden.sh` runs every profile's rewrite greedy over GPP and in-process (`prompt-inproc`: MLXServeEngine, the same
backbone and enhancer), and compares the texts. `scripts/release.sh` builds, checks, notarizes with the fleet's
`mlx-notary` profile and publishes the GitHub release; see the
[demo plugin](https://github.com/xocialize-code/gaea-plugin-demo) for signing and CI secrets.

## Licence

The plugin is Apache-2.0 (Gaea G-21). Qwen3.5's weights are Apache-2.0. The profiles' vendor prompts keep their own
licences, which prompt-enhance-kit records.
