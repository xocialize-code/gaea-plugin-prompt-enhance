#!/bin/zsh
# Every profile the plugin serves, its rewrite run greedy (temperature 0, seed 42) over GPP on the signed bundle
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run, shutdown) and in-process
# (prompt-inproc: MLXServeEngine, the same backbone and enhancer, on this package's dependency resolution), and the two
# texts compared.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh and `swift build -c release --product prompt-inproc`)
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/prompt-enhance.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
BIN=$(xcrun swift build -c release --show-bin-path)
CHECK=$BIN/gaea-plugin-check; INPROC=$BIN/prompt-inproc
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }

# profile, backbone, prompt, [width height]
golden() {
  local profile=$1 backbone=$2 prompt=$3 w=${4:-} h=${5:-}
  local params='{"profile":"'$profile'","mode":"always","temperature":0'
  local size=(); [[ -n $w ]] && { params+=',"target_size":{"width":'$w',"height":'$h'}'; size=(--width $w --height $h) }
  params+='}'
  $CHECK $B --operation x-gaea.prompt.enhance --model $backbone --lane int4 --params $params --seed 42 --text "prompt=$prompt" \
    --models-root "$MODELS" --budget 64000000000 --timeout 600 --session $OUT/$profile.gpp > $OUT/$profile-gpp.log 2>&1
  $INPROC --profile $profile --prompt "$prompt" --mode always --temperature 0 --seed 42 $size --models-root "$MODELS" \
    > $OUT/$profile-inproc.json 2>> $LOG
  python3 - "$OUT/$profile.gpp" "$OUT/$profile-inproc.json" "$profile" >> $LOG <<'EOF'
import json, sys
gpp, inproc, profile = sys.argv[1:]
result = next(json.loads(l[2:]) for l in open(gpp) if l.startswith("W ") and '"type":"result"' in l)
values = {o["name"]: o.get("value") for o in result["outputs"]}
mine = json.load(open(inproc))
print(f"{profile}: GPP {values['outcome']} in {result['seconds']:.2f} s (cold worker); in-process {mine['outcome']} in "
      f"{mine['run_s']:.2f} s, prepare {mine['prepare_s']:.2f} s, {mine['generated_tokens']} tokens at "
      f"{mine.get('tokens_per_second', 0):.1f}/s over whole calls")
print("  GPP:        " + values["prompt"][:240].replace("\n", " "))
assert values["outcome"] == mine["outcome"] == "enhanced", (values["outcome"], mine["outcome"])
assert values["prompt"] == mine["prompt"], "the texts differ"
EOF
  if (( $? == 0 )); then pass=$((pass+1)); say "PASS  $profile ($backbone): the same text over GPP and in-process"
  else fail=$((fail+1)); say "FAIL  $profile ($backbone): $(tail -1 $LOG)"; fi
}

say "# Prompt enhancer golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
golden flux2-klein qwen3.5-4b "a fox in the snow"
golden qwen-image qwen3.5-4b "a bakery storefront with a sign that says FRESH BREAD"
golden z-image qwen3.5-4b "an old lighthouse at dusk"
golden mage-flow qwen3.5-4b "a cat on a windowsill"
golden sensenova-u1.5 qwen3.5-9b "a poster for a jazz festival in Lisbon" 1024 1024
golden moss-image qwen3.5-9b "an infographic about the water cycle" 1024 1024
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
