#!/bin/zsh
# Step 15: score clean + every noisy condition through the real pipeline and print one table.
# Usage: qa/noise-bench.sh <model.bin> [label]
#   Env: anything cadence-headless honours (CADENCE_* A/B overrides) applies to every run.
#        NOISE_ONLY="babble" limits the noisy conditions to names containing that text.
# Writes qa/noise-results-<label>.json (label defaults to "baseline").
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="${1:?usage: qa/noise-bench.sh <model.bin> [label]}"
LABEL="${2:-baseline}"
[[ -d qa/fixtures/wer-noise ]] || qa/noise-fixtures.sh

TMP=$(mktemp -d)
CONDS=(clean)
for d in qa/fixtures/wer-noise/*/manifest.tsv; do
    [[ "$d" == *"/_sources/"* ]] && continue
    [[ -n "${NOISE_ONLY:-}" && "$d" != *"${NOISE_ONLY}"* ]] && continue
    CONDS+=("${${d:h}:t}")
done
for c in $CONDS; do
    if [[ $c == clean ]]; then man=qa/fixtures/wer/manifest.tsv; else man=qa/fixtures/wer-noise/$c/manifest.tsv; fi
    WER_MANIFEST=$man WER_OUT=$TMP/$c.json qa/wer-harness.sh "$MODEL" >/dev/null
done

python3 -B - "$TMP" "$MODEL" "qa/noise-results-$LABEL.json" $CONDS <<'EOF'
import json, os, sys, time
tmp, model, out, *conds = sys.argv[1:]
summary = {}
for c in conds:
    r = json.load(open(os.path.join(tmp, f"{c}.json")))["results"][model]
    summary[c] = {"wer": round(r["wer"], 4), "errors": r["errors"], "ref_words": r["ref_words"],
                  "asr_ms_mean": round(r["asr_ms_mean"]),
                  "worst": sorted(({"wav": f["wav"], "wer": round(f.get("wer", 1), 3), "hyp": f.get("hyp")}
                                   for f in r["fixtures"]), key=lambda f: -f["wer"])[:3]}
    print(f"{c:>12}: WER {r['wer']:6.2%} ({r['errors']}/{r['ref_words']})  asr {r['asr_ms_mean']:.0f} ms")
json.dump({"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "model": os.path.basename(model),
           "env": {k: v for k, v in os.environ.items() if k.startswith("CADENCE_")}, "conditions": summary},
          open(out, "w"), indent=1)
print(f"wrote {out}")
EOF
rm -rf "$TMP"
