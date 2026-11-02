#!/bin/zsh
# Step 15 noise bench corpus: the §30 English fixtures with background noise mixed under
# them at fixed SNRs. Two noise kinds that match Daniel's cafeteria report: "babble" (several
# other talkers at once, unrelated sentences, different voices) and "music" (a synthetic
# speaker-music bed). Output: qa/fixtures/wer-noise/<kind>-<snr>db/{*.wav,manifest.tsv},
# ready for WER_MANIFEST=... qa/wer-harness.sh.
#
# Deterministic: same say(1) voices + seeded music → same audio. Synthetic, so it ranks
# settings and catches regressions; it is NOT proof of real-room filtering (see qa/noise.py).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f qa/fixtures/wer/manifest.tsv && -f qa/fixtures/wer/s01.wav ]] || qa/wer-fixtures.sh

OUT=qa/fixtures/wer-noise
SRC=$OUT/_sources
rm -rf "$OUT"
mkdir -p "$SRC"

# Background talkers: voices NOT used for the target fixtures where possible, saying things
# a cafeteria table might, so whisper can't lean on overlap with the reference text.
talk() { say -v "$1" -r "$2" -o "$SRC/$3.wav" --file-format=WAVE --data-format=LEI16@16000 "$4"; }
talk Rishi    190 b1 "Did you see the game last night, they came back in the fourth quarter and nobody could believe it."
talk Flo      200 b2 "I have a chemistry exam on Thursday and I still have not started the problem set at all."
talk Ralph    180 b3 "Can you pass the napkins, and do you know if the dining hall is open late on Fridays."
talk Shelley  210 b4 "My roommate keeps leaving the window open and the room is freezing every single morning."
talk Grandpa  170 b5 "We should get pizza after this, there is a place downtown that stays open until two."
talk Sandy    195 b6 "The professor moved office hours again so now I have to go on Tuesday instead of Monday."

KINDS="${NOISE_KINDS:-babble music}"
SNRS="${NOISE_SNRS:-10 5 0}"

python3 -B - "$OUT" "$SRC" "$KINDS" "$SNRS" <<'EOF'
import os, sys
sys.path.insert(0, ".")
from qa import noise

out, src, kinds, snrs = sys.argv[1], sys.argv[2], sys.argv[3].split(), [int(s) for s in sys.argv[4].split()]
voices = [noise.read_wav(os.path.join(src, f"b{i}.wav")) for i in range(1, 7)]
beds = {
    "babble": noise.babble(voices, offsets=[0, 3100, 7700, 1900, 12000, 5300]),
    "music": noise.music(20.0),
}
fixtures = [l.rstrip("\n").split("\t") for l in open("qa/fixtures/wer/manifest.tsv")]
for kind in kinds:
    for snr in snrs:
        d = os.path.join(out, f"{kind}-{snr}db")
        os.makedirs(d, exist_ok=True)
        clipped = 0
        with open(os.path.join(d, "manifest.tsv"), "w") as man:
            for i, (wav, ref) in enumerate(fixtures):
                speech = noise.read_wav(os.path.join("qa/fixtures/wer", wav))
                mixed, peak = noise.mix_at_snr(speech, beds[kind], snr, offset=i * 4001)
                clipped += peak > 0.99
                noise.write_wav(os.path.join(d, wav), mixed)
                man.write(f"{wav}\t{ref}\n")
        print(f"{kind}-{snr}db: {len(fixtures)} wavs (rescaled to avoid clipping: {clipped})")
EOF
