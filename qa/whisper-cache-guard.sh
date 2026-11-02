#!/bin/bash
# Drop cached whisper.cpp builds made for a different macOS than the one we ship for.
# cargo does not rebuild whisper-rs-sys when MACOSX_DEPLOYMENT_TARGET changes, so a cache
# made before the 14.0 pin (or by a plain `cargo build`) keeps linking objects built for the
# build Mac's OS into an app that claims to run on 14.0. Removing the cache forces a rebuild.
# Usage: qa/whisper-cache-guard.sh <target-dir> <deployment-target>
set -euo pipefail
target_dir="$1"
want="$2"
shopt -s nullglob
for dir in "$target_dir"/release/build/whisper-rs-sys-*; do
    cache="$dir/out/build/CMakeCache.txt"
    [[ -f "$cache" ]] || continue
    have=$(sed -n 's/^CMAKE_OSX_DEPLOYMENT_TARGET:STRING=//p' "$cache" | head -n 1)
    if [[ "$have" != "$want" ]]; then
        echo "whisper cache built for macOS '${have:-unset}', want $want: rebuilding ($dir)" >&2
        rm -rf "$dir"
    fi
done
