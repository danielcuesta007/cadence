# STATUS — Cadence build progress

Updated: 2026-11-03 · Phase: **1 (MVP spine)** · Blueprint: docs/CADENCE_BLUEPRINT.md

## Step 19 — Private history failure recovery (2026-11-05)

Objective (Daniel): “can we wrap up that work pls?” Finish the paused privacy
fallback fix against current dev, preserving the installed AirPods A/B build.

DONE: failed history writes stay in RAM with visible copy/encrypted retry,
normal-quit discard confirmation, no transcript payloads in diagnostic traces,
legacy archive preservation, accurate privacy disclosure, and recovery of all
cached settings when reopening the store. Prepared 0.1.8/build14 with the
multilingual model, stable signer and macOS14 minimum; no install performed.

VERIFIED: recovery33/33 (normal and CADENCE_DEBUG), Rust131, hotkeys139,
delivery20, capture38, lifecycle17, stats39, widget16, appearance10,
insertion9; store key policy checks, Python packaging/noise/cache17, site37.
Planted discard-failed-write/double-count/omitted-disclosure regressions fail.
The native encoding test first exposed an Objective-C exception; JSON validity
guards fixed it and the test now passes. All failure tests used isolated
stores; no live history, keys or legacy files were modified.

ARTIFACT: Cadence0.1.8(14), SHA-256 `df13078cf20d17af1529e452858252fa295d94d4a716154b24c7986fc84a71a4`.
RELEASED: #108 squash→dev `8d08849`; reviewed #109 merge→main `c05040d`, dev retained.
GitHub v0.1.8 published before production deployment `65f5fe94`. Downloaded the
public latest DMG: exact same SHA-256. All 28 live site files match dist bytes;
Cask, one-line installer, download page and release digest agree. Feature and
release CI pass. Full receipt: dist/privacy-release-receipt.json (generated).
No active source handoff; implementation and publication are complete.
No real speech/first-install or macOS14 hardware test was performed. The installed
AirPods experiment remains a separate acceptance gate (#106), not part of this
public release. Crash/forced quit can lose unsaved RAM recovery; prior plaintext
files and local key custody are disclosed, not silently migrated/deleted.

FILES: AppMain, HistoryStore, EffectRouter, PendingHistory, DashboardWindow,
HistorySelfTest, main.swift, tests.yml, README, DECISIONS, privacy page,
releases.json, Cask and installer. Worktree ~/cadence-readiness,
fix/private-history-fallback. Prior pause checkpoint is preserved in branch history.

## Step 15 — Background noise in loud rooms (2026-11-02)

Objective (Daniel, verbatim): "music is always playing in my earbuds but ther was also some in
the speaker saround me, i was in nthe cafeteria".

**What the live log showed** (~/.cadence/logs/cadence.log, 560 captures): almost every capture
is the MacBook Pro Microphone @ 44.1 kHz with voice processing off — it hears the whole room.
There is no loopback path, so earbud music is not captured. But 121 captures (22%, incl.
20:14–20:16 on 1 Nov) logged an opaque `CADefaultDeviceAggregate-…`: the built-in-mic pin's
result was discarded, so the log could not say which mic was really used.

**Measured (synthetic, `qa/noise-bench.sh`, ggml-small.bin, English pinned, WER):**

| condition | before | filter + suppress-nst | filter + beam 5 |
|---|---|---|---|
| clean | 1.33% | 1.33% | 1.78% |
| babble 10 dB | 4.89% | 4.89% | (not run) |
| babble 5 dB | 5.78% | 5.78% | (not run) |
| babble 0 dB | 17.78% | 17.33% | **13.78%** |
| music 10 / 5 / 0 dB | 1.78 / 1.78 / 2.22% | (not rerun) | (not run) |

Findings: **music is not the problem** (2.2% even at 0 dB); **nearby voices are** (17.8% at
0 dB). At 0 dB whisper also captioned a whole sentence as "[indistinct chatter]" — Cadence would
have typed that into the document. suppress-nst is a one-word change: not a lever. **Beam 5 is the only decode lever
that moved babble** (−9 errors, ~22% relative at 0 dB) but costs one clean-audio error and
~70% more ASR time — NOT made default; candidate for an opt-in "noisy room" mode or for
switching on only when the room is measured loud (Daniel's call). Synthetic = ranking and
regression only; no real-room claim. Raw: qa/noise-results-*.json.

**Shipped on feat/step15-noise (65d2aab+):**
- `InputRoute` (CadenceCapture): capture-start log names aggregate members and the pin result
  (`pin=FAILED(status)`); the warm path re-pins the built-in mic when the route drifted, but
  never re-hammers a pin the system refused for that same route; the menu shows the real mic
  in plain words ("AirPods · 24 kHz · headset mic, lower quality"). `cadence selftest-capture`
  25/25, in CI.
- `strip_non_speech` (core/asr): sound captions ([indistinct chatter], (music), *laughs*,
  ♪ lyrics ♪, [BLANK_AUDIO]) are never typed; real brackets ("items[0]", "(see appendix)")
  survive. All-caption results become the existing "empty" outcome. 7/7 asr tests.
- Bench: `qa/noise.py` (+ `qa.test_noise` 8/8, in CI), `qa/noise-fixtures.sh`,
  `qa/noise-bench.sh`; A/B switches CADENCE_BEAM, CADENCE_SUPPRESS_NST, CADENCE_KEEP_CAPTIONS
  (defaults unchanged). Every new test was watched failing once on a planted bug.

**Not done / not claimed:** Voice Isolation (AUVoiceIO) stays experimental + off — it cannot
be benched offline and its teardown froze the app before; needs a consented live A/B (same
lines, quiet vs real cafeteria, VP off vs on). A background-speech gate (only the loudest,
closest talker) is the next lever the numbers point to. Bench latency figures are inflated
(machine load average 35–63 during runs); WER is deterministic.

## Step 14 — Versions in one place, and a multi-page site (2026-11-02)

Objective (Daniel, verbatim): "make sure all verisons are super eaisly managelbe, add a verison
history timelien on the site, instead of making it one long scrooable page, lets make the
wbsite oages itelsf, PLEASe aduit nad irmpvoe the whoel experince".

releases.json (repo root) is the ONE version list, newest first. qa/package-app.sh reads the
app version/build from its first entry; qa/make-dmg.sh refuses any other version and, after
building, stamps that entry's sha256/date (`node site/pages.mjs stamp`), the cask and
install.sh, and regenerates the site. The site is now 7 pages (home, features, download,
versions, help, about, legal); site/pages.mjs writes the shared header/footer and the
release blocks (timeline, latest line, checksum) on every build, so nothing can go stale.
Phones keep the page links as a scrollable row (they used to be hidden). New: controls
table, update/rollback/remove section, troubleshooting (including noisy rooms, honestly
marked as being worked on).

Verified: site tests 35/35 (shared layout, freshness against releases.json, validation of
bad lists, stamping, old-link forwarding), qa 19/19 (make-dmg with releases.json, version default, wrong app
version refused); checked in Chrome on desktop. Not checked: real phone width (the window
would not resize).

## Step 13 — Even more forgiving hands-free, and tap-then-hold (2026-11-01)

Objective (Daniel, verbatim): "the double tap shoudl be even mor eforgiving pls and hsoiudl
be also abel to be riggerterfe with a long hold, the one tap end till applys".
Interpreted as tap, then press-and-hold (a single long hold stays push-to-talk, or every
held dictation would latch). Changes: first tap ≤0.45 s (was 0.35); gap = macOS
double-click speed + 0.2 s, clamped 0.6–1.0 s (0.7 s default; was 0.5); the second press
may be any length and latches the moment it goes DOWN (pill reads hands-free during the
hold; a chord within 0.45 s of that press still retracts, later typing keeps the speech);
one clean owner tap still finishes. Menu hint
and README updated.

Verified: hotkeys 123/123 (timing boundaries rewritten for the new values; new
tap-then-hold, long finish press, Escape during a held second press, hands-free-off never
latches); planting the old "second press must be quick" rule fails 6 checks; delivery 20/20.
Trade-off: a lone tap now waits 0.7 s (default) before stopping; a short hold followed by
another press within the gap latches hands-free instead of starting a new dictation.

## Step 12 — Easier Mac download without notarization (2026-11-01)

Objective (Daniel): "i used the hombre version and it didnit work for me"; "make this
download super easy" without paying for Apple notarization yet. Root causes reproduced:
the cask installed into /Applications (root:admin 775; non-admin accounts fail), and
Homebrew quarantines what it installs ("Homebrew Cask" flag), so the unnotarized app is
blocked on first open. Fix (PR #77): documented `brew install --cask
--appdir=~/Applications cadence`; relative `app` target so Homebrew remembers the folder;
`postflight_steps` (old `postflight` fallback) clears quarantine after sha256 check;
Homebrew 7 macOS deprecation fixed; README leads with the one-line installer (already
no-admin, checksum, unquarantine). App version bumped to 0.1.5 (8).

Verified: real Homebrew 7.0.11 installs from a throwaway tap into a not-yet-existing
appdir (created, no warnings, quarantine cleared; control without the step stays
quarantined); uninstall used the remembered folder; qa/test_cask.py 6/6 (3 fail on the old
cask); qa OK; site 29/29. Users get the cask fix only once it reaches main (the tap reads
main) and the next release stamps version/sha256. Only a browser .dmg download still needs
Open Anyway; that remains until notarization, which Daniel has deferred.

## Step 11 — Forgiving hands-free double-tap (2026-11-01)

Objective (Daniel): double-tapping Option "requires overly precise timing"; hesitant users
should still start hands-free. Fix: PTTArbiter's single 0.3 s `tapWindow` (used for BOTH
tap length and the pause between taps) is split into `PTTTiming.maxTapDuration` 0.35 s and
`interTapGap`, which follows macOS double-click speed clamped 0.4–0.8 s (0.5 s default).
Only the pause is generous: holds still start and stop immediately; a lone short tap
stops when the gap runs out. Second press counts strictly before the deadline, matching
`expire`. Pill shows "listening · tap again for hands-free" while a first tap is pending.
Unchanged: owner-key ownership, foreign key ignored, chord/typing retraction, Escape,
single-tap finish, no Return on finish.

Verified: hotkeys 110/110 (36 new: hesitant gaps, both sides of gap and tap-length
boundaries, long second press, foreign key in gap, Option typing/chords, Escape in gap,
no duplicate finish, ordinary hold, pill wording); planting the old conflated window fails
9 of them. Delivery 20/20, insertion pass, qa 11/11, release Swift build. Not yet
installed into ~/Applications; physical feel on the keyboard is Daniel's acceptance.
Known limit: a press after the gap while the previous lone tap is still transcribing is
rejected as busy (unchanged; longer gap makes it rarer).
Trade-offs (from review): a press of 0.35 s or less now waits for the gap (0.5 s
default, up to 0.8 s with slow double-click speed) before stopping, not 0.3 s; and a
second press inside the gap continues the same recording rather than starting a new one
(both phrases land in one dictation, nothing is lost). Git: branch fix/forgiving-double-tap,
PR #76 → dev. NEXT: review/CI/merge, release PR, local install, Daniel's keyboard test.

## Step 10 — Single-tap finish and microphone visibility (2026-11-01)

Daniel requested double-tap START / single-tap FINISH for long hands-free dictation,
clearer versions and better recognition with music. Gesture update: the owning Option
key's next clean release stops once; the second starting tap still latches, foreign
keys do not stop it, chords/typing cannot accidentally finish, and ordinary holds remain.
Pill/menu/README wording now matches. Package version0.1.4(7), visible in the app menu.
Dictation Settings shows actual Input and Voice filtering state, including processing
fallback, rather than implying the saved preference is active.

Verified: new regression failed on old behavior; revised gesture suite74/74, delivery20/20,
insertion9/9, release Swift build and packaging5/5 pass. Rust core unchanged; reused the
exact released Whisper/Metal static library from cadence-dictation-controls. Review/CI,
merge and installation receipts will be recorded in the local continuation checkpoint.

Music/noise work remains OPEN: actual recent captures used MacBook Pro Microphone@44100Hz
with voice processing inactive. No system-output loopback capture. Playback destination
is not yet established; asked Daniel earbuds/headphones vs speakers. Voice Isolation
remains experimental/off after the known AUVoiceIO teardown freeze; no untested DSP,
Bluetooth-route or permission change. Do not claim improved noise suppression from this
visibility/control update. Next: controlled route/noise comparison and safe processing
lifecycle work, followed by approved correction learning/snippets improvements.

Daniel explicitly replaced the reserve for this pass: hard stop at7% (2026-11-01).
This is a session-specific exception; do not edit global usage limits or use a reset.

## Step 9 — Dictation delivery and hands-free controls (2026-11-01)

Objective (Daniel): “available to copy and paste in if it missed the mark”; double-tap
Option to start/finish a long dictation; optional live insertion in a feature setting.
Step 9 follows the eight numbered milestones in the existing October audit; it does
not claim that the earlier manual acceptance items are closed.

Implemented: Dictation Settings with clipboard recovery on by default, double-tap
hands-free on by default, and Experimental Features → Live Insertion off by default.
Normal holds retain immediate release; only short taps wait 300 ms for a second tap.
Language keys cannot interleave. Chords/typing retract accidental holds; shortcuts during
hands-free break the tap sequence without cancelling speech. Escape, tap failure and
completion reset gestures. Live previews verify field identity, value and caret; user
interference stops writes and routes the full final to clipboard. Cancellation restores
only an unchanged preview; unsupported fields insert on finish. Pill distinguishes
preview, provisional writing, verified insertion, unconfirmed sending and recovery.

Audit fix: the old 60-second audio ring silently discarded opening speech. Capacity is
now 30 minutes (57.6 MB), with automatic finalization at 29 minutes. Partial decoding
copies only its recent eight seconds; the final still uses the complete recording.

VERIFIED: Rust workspace 117/117; release Whisper/Metal + Swift build; hotkeys 69/69,
delivery 20/20, insertion 9/9, existing store/lifecycle checks, packaging 5/5.
Planted regressions caught: old one-minute capacity, missing latch, disabled clipboard
preference guard, and missing live field/caret/focus validation. CI now builds the Swift
shell and runs its hotkey/delivery/insertion checks without requiring a model.

NOT VERIFIED: real speech with physical double-tap; multi-minute real ASR quality;
manual live insertion across third-party apps. Streaming text is provisional and may
pause for ambiguous overlapping words until the authoritative final. If the user edits
a preview, it is left intact and must be removed before pasting the final. No public
DMG/tag/site deployment is part of this change. Existing latency diagnostic source and
rollback app are preserved; this work does not claim to fix that intermittent startup.

FILES: `platform-macos/{Hotkeys,Insertion,Overlay,App}`, `core/{ffi,orchestrator}`,
README, CI and packaging microphone description. Branch `feat/dictation-controls` in
`~/cadence-dictation-controls`; review/PR/merge and local installation receipt pending.
NEXT: finish the Codex review, merge feature → dev → main, install with the existing
stable signature/model, then Daniel's physical speech acceptance.

## Brand voice — Keep your cadence (2026-10-29)

Daniel approved **Keep your cadence.** with **Your words. Your rhythm.**
(“yeah all of it go”). Applied the direction to the hero, page/share metadata,
announcer ribbon, README and brand reference. The plain explanation and explicit
“Nothing leaves your Mac” promise remain alongside the brand line.

Verified: site 28/28; desktop preview and 390px/320px phone layouts inspected,
with no horizontal overflow. This is a website/documentation update; verified
v0.1.3 download, app branding and widget instructions remain current.

## Handoff

_No active source handoff._ Step 19 is released and live (see receipt above).
Installed local app remains 0.1.7(13) with the separate #106 AirPods experiment;
Daniel has not answered whether to replace it with stable 0.1.8. Do not merge
#106 without its A/B acceptance or overwrite the installed experiment silently.
Source/history/keys and backups were preserved. Real voice and first install
on another account/macOS14 hardware remain manual acceptance, not completed tests.

### Historical handoffs (superseded by Step 19 above)

**State (2026-11-03):** Cadence **0.1.7 (13) is released** and live (Daniel: "publish pls
yes u have all permissions to work!", 2 Nov 2026).
- Release: https://github.com/danielcuesta007/cadence/releases/tag/v0.1.7 (tag at 024d574,
  published as latest 2026-11-02T20:57Z). Cadence.dmg sha256
  `aefc1c01e1dac4c46b657b211514859cc0c25d67ff3bbdc3b03e67d957d1cf98`. The public
  latest-download hash was checked and matches.
- main 97b70ab (release PR #103 = #96 #97 #98 #99 #100 #101 #102, merge commit, dev kept).
  #100 (Plans page) and #101 (extension points) came from a parallel session. They are on
  main but not in the 0.1.7 binary.
- Site deployed from main to https://cadence-dictation.pages.dev (deploy 7d206519). The live
  /download page, install.sh and the cask on main all name 0.1.7 / aefc1c01. /promises is live.
- Installed on Daniel's Mac: 0.1.7 (13), model pin 1be3a9b2. Rollbacks:
  ~/Applications/Cadence.app.pre-v017-20261102T154715 (0.1.6 b12) and older pre-v016* bundles.
- Next: Step 17. Daniel dictates in the dining hall with Noisy Room Mode ON and reports what
  he said vs what was typed.

**How releases work now:** add an entry at the top of `releases.json` (version, build, title,
highlights, date/sha256 null) → `qa/build-shell.sh` → `qa/package-app.sh` (reads version)
→ `qa/make-dmg.sh` (stamps releases.json, cask, install.sh, site pages) → tag + `gh release
create --draft` + `gh release upload` (retry on 408) + publish → PR stamps to dev → dev→main →
`cd site && node build.mjs && CLOUDFLARE_ACCOUNT_ID=<personal account, see private notes> npx
wrangler pages deploy dist --project-name cadence-dictation --branch main`. After editing
releases.json or the shared header/footer, run `node site/pages.mjs` (tests fail on stale pages).

**Build environment:** worktree ~/cadence-single-tap. Build with
`CMAKE=$HOME/cadence/tools/cmake-local/cmake-3.31.7-macos-universal/CMake.app/Contents/bin/cmake
qa/build-shell.sh`. `.cargo/config.toml` pins MACOSX_DEPLOYMENT_TARGET=14.0 for every cargo
build, and `qa/whisper-cache-guard.sh` drops an old whisper.cpp cache built for another macOS.
Model: ~/cadence/models/artifacts/ggml-small.bin (pin 1be3a9b2…; pass CADENCE_BUNDLE_MODEL).
Other worktrees (capture-latency, dictation-controls, readiness, ~/cadence) hold uncommitted
research: do not reset or stash them.

**0.1.7 (13) — caption-filter fix, RELEASED 2 Nov 2026 (see State above).**
#97 fixed issue #95: removing a noise caption only tidies its own gap, and "[Music] .5 mg"
no longer becomes "5 mg" (a 10x dose bug that shipped in 0.1.6). See "How releases work now".

**0.1.6 (12) is RELEASED (2 Nov 2026, Daniel approved).** Tag v0.1.6 at 9253558; release
https://github.com/danielcuesta007/cadence/releases/tag/v0.1.6, Cadence.dmg sha256
`7e1933c358aa05451e77b2749e5bb96cc34d8ddd0aa4232c83580ff5546d16d3` (the downloaded asset
was checked against it). main b72a0db (release PR #94 = #85 #88-#93, merge commit, dev kept).
Site deployed from main, and the live download page, install.sh and cask all name 0.1.6.
Installed on Daniel's Mac: the exact binary from the DMG. Rollbacks:
~/Applications/Cadence.app.pre-v016b12-20261102T124437 (0.1.6 b11),
~/Applications/Cadence.app.pre-v016b11-20261102T095843 (b10),
~/Applications/Cadence.app.pre-v016-20261102T071257 (0.1.5).

**Mic choice (PR #91, Daniel: "auto choose the headphone mic if there are earbuds in"):**
"Always Use Built-in Microphone" now defaults to OFF. RoutePolicy.pinTarget works like this:
if the macOS default input is Bluetooth, use it; if it is another non-built-in mic (such as
USB), follow the default; otherwise use the first connected Bluetooth mic. USB is never
treated as a headset. A device-list listener re-picks the mic when earbuds come and go.
Trade-off: dictating through AirPods puts them in call mode (music drops to call quality).
**Empty results are now logged** (#92): "utt-N: nothing usable heard …". Before this, a
dictation where only noise was heard left no trace in the log (Daniel's 12:47 dining-hall capture).

**First field data (dining hall, 2 Nov, Noisy Room Mode OFF):** capture used the AirPods mic
at 48 kHz. Daniel: "the first half of that dictation was right, the second was not". One
7.4 s capture came back empty.

## Step 16 — Noisy Room Mode, and a macOS 14 build fix (2026-11-02)

- **Noisy Room Mode** (Dictation Settings → "Noisy Room Mode (Slower, Better with Voices
  Nearby)"): off by default, can only be changed between dictations, saved as the
  `noisy_room` feature. When it's on, the refined pass uses beam search width 5 (bench: about
  22% fewer errors with chatter at speaker level, ~70% slower, one extra error on quiet audio).
  The instant pass stays greedy. The overrides are applied before warm-up, so beam search is
  warmed too. `CADENCE_BEAM` still overrides, and the log says so. The log shows
  `noisy-room=on` on the core-ready line and records each toggle. DECISIONS #23.
- **macOS 14 build fix:** this worktree's whisper.cpp cache had an empty deployment target. It
  was built before the 14.0 pin and cargo never rebuilt it, so 0.1.6 (10) and earlier local
  builds linked macOS 26.5 objects (about 1,200 linker warnings) into an app that claims 14.0.
  Fixed at the root with `.cargo/config.toml [env]`, which was verified with a fresh build and
  no exported variable. The guard cleans up old caches. 0.1.6 (11) builds with 0 such warnings.
- The long-recording FFI test now allows 30 s per step (it timed out at load average ~33,
  with or without the change).
- Phone-width check of the site: **done**. The local build was rendered in real 320 px and
  390 px iframes (desktop Chrome can't open a window that narrow, which explains the earlier
  "would not resize"). Home, download, help, versions and features lay out cleanly. At 320 px
  the header's Download pill sits off-screen in the sideways-scrolling nav row (by design);
  the hero's "Download for Mac" button covers it.
- Tests: Rust 124 (2 new, each watched failing on a planted bug), selftest-capture 28/28,
  qa unittest (new `qa.test_whisper_cache_guard`, in CI), site 35/35. Reviewed by Claude
  (8 findings, 7 fixed, 1 explained on the PR).

**NEXT (Step 17):**
1. Daniel dictates in the dining hall with Noisy Room Mode ON. Compare against the OFF run
   above (ask him what was said vs typed; the history is encrypted). Check the log for
   "nothing usable heard" lines.
2. If voices still win: a background-speech gate (keep only the loudest, closest talker), or
   a consented Voice Isolation A/B now that the AirPods mic is in use.
3. Issue #95: strip_non_speech re-tidies spacing beyond the removed caption (low impact).

## Favicon cleanup and public-download verification (2026-10-29)

Completed after the quota reset. PR #59/#60 merged; main `b915874` deployed to
`cadence-dictation`, production deployment `0f4ee3be`. All 21 public files match
the build byte-for-byte; site 28/28 and PR CI pass. Both pages use new versioned
cobalt/pink browser/touch/share icons. Updated brand reference no longer shows
the obsolete boxed/red-centre mark. Existing Chrome Cadence tab was reloaded.

Downloaded the actual public latest asset: v0.1.3 (5), SHA-256
`63e315ea93b98916ac648cd7b1d70ad8cfe885bdf94ba031f3dea38cf57c31c1`.
Signature verified; bundled multilingual model matches its pin. Public app's
appearance 10/10 and widget 16/16 pass. Pixel scans of its actual icon,
light/dark dashboard and widget preview found no old green accents.

The existing Vitals tile had one additional green element: its shared Live dot.
Scoped it to Cadence pink (other engines keep their indicators), added four
color checks, and confirmed a planted green regression fails. Small/Medium
live-state renders have no green pixels. Released wow-command-center #213/#214,
main `9079185`; production binary rebuilt, same stable signing requirement
verified, and restarted. Shared dirty Command Center source checkout remains
untouched; reviewed source stays in `~/ai-search-tracker-cadence-brand`.

Real speech/first-install manual acceptance remains outstanding; preserve the
original backup apps. Brand voice was subsequently approved; see the current brand-voice checkpoint above.

## Waveform-only widget mark (2026-10-29)

Daniel requested removing the white plate around the widget logo, keeping the
colored waveform. Removed only that background in Cadence and Vitals; logo
clicks, layout and metrics are unchanged. Cadence source PRs #55/#56, tag
v0.1.3 at 20cc6eb, build 5. Widget 16/16 and source CI pass; preview inspected.
DMG SHA-256 `63e315ea93b98916ac648cd7b1d70ad8cfe885bdf94ba031f3dea38cf57c31c1`.
Existing Vitals change shipped through #211/#212; rebuilt and activated with
the same stable signer. App icon's white plate remains unchanged (widget-only
request). Original rollback apps remain pending Daniel's real dictation.
At this release, homepage brand-line options were still under discussion; the subsequent brand-voice checkpoint records the approved direction.

## Desktop widget and v0.1.2 release (2026-10-29)

Daniel authorized the pink/cobalt release and site deployment, plus an optional
public desktop widget and matching branding for his existing Vitals tile.
The feature lives in `DesktopWidget.swift`: opt-in from **Show Desktop Widget**
in the menu, the same wide layout as Vitals (today/week words, streak, pace, saved time and
all-time words), local totals only, draggable, saved visibility/position, hide/open
controls, stale-date protection, and no extra app/server dependency. Download
page and DMG instructions explain the option. Vitals branding is isolated in
`~/ai-search-tracker-cadence-brand` (three widget files only).

Verified so far: 16 widget checks (a planted missing date guard failed), site
27/27, DMG packaging 5/5, hotkeys 37/37, lifecycle 17/17, stats 39/39, Vitals
format harness. Rendered the public tile and both sizes of the Vitals tile.
Release builds now pin native dependencies and SwiftPM to macOS 14; the old
build inherited this Mac's macOS 26.5 target despite advertising Sonoma support.
The multilingual model remains `ggml-small.bin`, hash pinned by `make-dmg.sh`.

Released as **v0.1.2** at main `e8fdd88` (PRs #51 and #52), with
`Cadence.dmg` SHA-256 `f6c33ee8cc0398ebef900e22953b1ccb17c13285d63b9018faa19fbcdad35721`.
Installed app doctor: 0.1.2 (4), engine/hotkeys ready, bilingual model available,
Microphone/Accessibility retained, login enabled. Full Rust suite: 114 passed;
appearance 10/10. Matching tile's native logo/open callback and hide control
were exercised live. GitHub's macOS jobs were queued at merge; equivalent
local checks completed, and site/release CI subsequently passed.

Source implementation handoff: none. Real speech and an actual macOS 14 Mac
remain manual acceptance. Keep `~/Applications/Cadence.app.prev-20261029` and
`~/Applications/Cadence.app.pre-v012` until Daniel confirms real speech.
The existing Vitals tile was released via wow-command-center #209/#210
(main `8839ce7`) and its stable-signed app binary was rebuilt and activated.

## Lifecycle diagnostics (2026-10-14)

Daniel reported Cadence down; the process was absent. Reopening restored dictation,
confirmed by Daniel. No crash report explained the prior exit; login registration was
enabled and the machine had not rebooted since that session started. Historical unified
logs were inaccessible. The original exit cause remains unknown.

**Implemented and installed locally:** content-free atomic `~/.cadence/logs/lifecycle.json`
records startup, 60-second heartbeat, engine/hotkey readiness, and known shutdown reasons.
The previous session is preserved on launch. Menu quits, app quit/logout, system shutdown
requests and known startup failures have explicit evidence; abrupt exits remain unexplained.
Lifecycle events go to `cadence.log`, flushed synchronously at launch/exit. Corrupt or
unsupported records are preserved; write failures do not block dictation.

`Cadence.app/Contents/MacOS/Cadence doctor` checks running processes, permissions, model,
login registration, lifecycle history and crash metadata; returns recovery suggestions
without reading transcripts, audio, keys, or raw log contents. **Open Diagnostic Logs…**
is available in the menu. Recovery instructions are in README.md.

**Verified:** release Swift build; 17/17 lifecycle checks, each observed failing with
deliberate implementation faults; 37/37 existing hotkey checks. Real installed-app
termination persisted `application_quit_or_logout` and flushed its log. While stopped,
doctor returned 1 and suggested reopening. Relaunch preserved the previous exit; doctor
returned 0 with engine/hotkeys ready, permissions granted, model present, login enabled.
Installed app = 0.1.1 (build 3), stable signing requirement unchanged and signature verified.
Real speech after this update, reboot behavior, and system shutdown notification delivery
are not yet live-verified; pure reboot classification is regression-tested.

**Git / handoff:** implementation PR #38 (`fix/lifecycle-diagnostics` → `dev`), based on
main `a399661`. Daniel authorized publication and release through `dev` → `main` on
14 October. Local source worktree: `~/cadence-lifecycle-diagnostics`; close-out commit
and release state are recorded in `~/brain/memory/cadence-runtime-safety.md`. Shared
checkout's unrelated `site/.wrangler/` files are excluded from this change. Pre-update
rollback bundle is under the temporary directory recorded in that memory note.
On a future outage run the installed `doctor` command before restarting.

**Review correction (PR #38):** preserving an unreadable lifecycle file originally also
skipped shutdown log flushing. The monitor now retains an in-memory session while keeping
the original file untouched; two additional checks reproduced the fault before the fix.

## Two-key push-to-talk (2026-07-26) — the language decision, dissolved

The second pass left a decision open: default to Automatic (bilingual, but ~160 ms of detection
on every utterance and 21.5 % Spanish WER) or to pinned English (faster and far better Spanish
when pinned, but a menu trip to switch). Daniel's answer was to refuse the trade: bind a second
key. **Right-Option and Left-Option are now both push-to-talk, each pinned to its own
language** — English and Spanish by default. Neither pays detection, Spanish gets the pinned
13.6 % instead of 21.5 %, and switching languages costs a different finger instead of a menu.
Either key can still be set to Automatic, and the second key can be set to Off if Left-Option is
needed for typing.

The first attempt bound Right-Control and was **dead on arrival**: Apple laptops don't have
one. The MacBook bottom row is fn / control / option / command / space / command / option /
arrows — a single Control, on the left. Right-Shift types capitals and Right-Command is half of
every right-handed ⌘ shortcut, which leaves the Option pair as the only two keys that are both
present and unclaimed. Telling them apart needs the device-dependent modifier bits
(NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK); the general `.maskAlternate` reports both Option
keys as one.

Left-Option is the more dangerous half of that pair, because it is the Option people actually
use — ⌥e for an accent, ⌃⌥⌘Z to undo — which is what invariant 3 below exists for.

**Defaults changed.** `dictation_language` unset now means `en`, not `auto`, and the new
`secondary_language` unset means `es`. Daniel had never explicitly chosen a language — the log
has no `dictation language →` line in nine days — so this changes a default he never picked
rather than overriding a choice he made.

**Three invariants are pinned by `cadence selftest-hotkeys`** (24 checks), because all of them
fail silently rather than loudly:
- *One dictation at a time.* A second PTT pressed mid-utterance is ignored, and only the key
  that started an utterance can end it. Without this the two languages could interleave inside
  one utterance, or a stray release could cut a live dictation short.
- *A chord is not a PTT.* If another real modifier is already down, the user is typing a
  shortcut. Chord rejection deliberately applies to **starts only**: a release arriving while
  another modifier is held must still stop the dictation, or pressing a modifier mid-utterance
  would strand the app in capturing forever.
- *A hold can be retracted.* The rule above only catches chords whose other modifier lands
  first — and ⌃⌥⌘Z pressed with a left hand presses Option **first**, so the dictation has
  already started by the time the chord is recognisable. So anything proving the user was not
  speaking retracts it: a foreign modifier joining the hold, or any ordinary key being typed.
  The second case is what makes ⌥e (é) safe — without it every accented character would leave
  a stray empty utterance behind. Retraction fires within milliseconds, before there is speech
  to lose, and exactly once; the eventual key release is then a no-op. The app cancels silently
  (no overlay flash), since the user never meant to start a dictation, and clears its
  swallowed-PTT flag — a retracted hold never delivers the `onPTTUp` that would normally
  clear it, so a stale flag would eat the *next* dictation's release.

The arbitration lives in a pure `PTTArbiter` struct so it can be exercised without synthesizing
CGEvents — the same no-XCTest pattern as `insertctl selftest` and `selftest-stats`.

## Ship-ready pass (2026-07-25, third pass)

Housekeeping so the repo matches the app, plus a disk reclaim. No dictation behaviour changed.

**3.7 GB of build output deleted** (`target/` 2.2 G, `platform-macos/.build` 1.0 G, `dist/`
474 M; repo 5.1 → 1.4 GB). `models/` was kept — slow to refetch and the WER harness runs against
it. Before deleting, the installed app was re-verified self-contained, because the 7/19 cdylib
trap is exactly this failure mode: `otool -L` shows only system frameworks and `/usr/lib`, no
dev-tree dylib and no dev-tree `LC_RPATH`; the model resolves from the bundle's own
`Contents/Resources/models/`; `dist/Cadence.app`'s binary was byte-identical to the installed
one; and `lsof` on the running process showed zero open files under the checkout. The
`openssl-build/install/lib/{engines-3,ossl-modules}` strings baked into the binary are a red
herring — those directories already did not exist and OpenSSL falls back to built-in providers.
The rest of the absolute paths in the binary are `__FILE__` strings in ggml assertions, not
runtime lookups. Cost of the reclaim, measured rather than guessed: a full rebuild is ~52 s of
Rust plus ~35 s of Swift, not the ~10 min first estimated — whisper.cpp and SQLCipher cache
outside `target/`, so deleting it does not force their recompile.

**README rewritten.** It was still the Phase 0 insertion-spike document — it described a
prototype while the repo shipped a daily driver. Now covers what the app does, requirements
(including CMake, the one dependency a fresh clone does not get, since `tools/cmake-local/` is
gitignored), why stable signing matters for TCC grants, where user data lives and what deleting
the keychain item costs, every test entry point, the measured numbers, and the known trade-offs
stated plainly rather than smoothed over.

**Two hardcoded checkout paths removed** (§ works-anywhere). `main.swift`'s last-resort model
fallback named `~/cadence/models/artifacts/ggml-base.en.bin`, so a clone anywhere else pointed
at a path that does not exist — or, on a shared machine, at another user's home. It now walks up
from the executable to locate the checkout, with a relative literal as the final arm so a
genuine miss reports "no such file" instead of a misleading absolute path. Verified by running
the bare binary from `/tmp` with no `CADENCE_MODEL` and no bundle: it resolved correctly.
`qa/matrix-driver.sh` is sourced, so `dirname "$0"` belongs to the calling shell there; it asks
git for the checkout root instead, and both paths take env overrides. Repo-wide grep for
`danieljoshuacuesta`, `~/cadence`, `$HOME/cadence` across Swift/Rust/shell/TOML/Python is now
clean. `Cargo.toml` said `license = "UNLICENSED"` while `LICENSE` is MIT; the manifest matches.

**Verification:** 92 Rust tests, `insertctl selftest` 9/9, `cadence selftest-stats` 18/18, full
rebuild from empty `target/`, repackaged, reinstalled, relaunched — core ready in 150 ms.

**Still open, unchanged by this pass:** the `verify=contradicted` watch has only **one** live
dictation since the readback-folding fix installed (17:56, verdict `verified`). One sample is
not evidence; the log still shows 14 historical contradictions, all predating the fix. This
stays open until a handful of real terminal dictations accumulate. (The language-default
decision that was open here is now resolved — see the two-key section above.)

## Latency + Spanish eval (2026-07-25, second pass)

Follow-on to the audit: "make the thinking faster", plus the two gaps the audit left open
(no Spanish fixtures, no Swift tests). Everything below is A/B'd on the §30 harness, which
reports WER and ASR latency together — so no speedup was accepted without checking what it cost.

**Refined pass: ~660 ms → ~500 ms, WER unchanged at 1.778 %.** Two levers, both accuracy-neutral.
Absolute latency drifts ±50 ms run to run on this machine (480/495/554 ms across three identical
runs), so treat the deltas below as the finding and any single number as approximate; WER, by
contrast, reproduced exactly (4/225 errors) in every run:
- **Flash attention** (`WhisperContextParameters.flash_attn`, off by default in whisper-rs):
  659 → 537 ms, identical WER. A fused attention kernel — same arithmetic, less memory traffic.
- **Encoder window** (`audio_ctx` 1500 → 1280): ~537 → ~500 ms, identical WER. Whisper always
  encodes a 30 s mel, so a 4 s utterance pays for 26 s of silence. Sizing the window to the
  audio is *not* free, though — the sweep in `refined_audio_ctx`'s doc comment shows the cliff
  (1024 → 2.2 %, 768 → 3.6 %, sized-to-audio → 4.0 %). 1280 is the knee; we take the free 12 %
  and stop.

**Insertion: the 250 ms paste settle is now a poll, not a sleep.** The wait exists so the
clipboard restore cannot beat the target to the pasteboard — but a readback that already contains
our text proves the target is done, so verifiable targets stop waiting the moment it lands
(typically 40–80 ms). Opaque targets (VS Code, web views, Spotlight) still wear the full settle.
Combined with the ASR work, perceived end-to-end goes from ~913 ms to ~575 ms.

**Rejected, with the measurement that killed it:** reusing the instant pass's language detection
so "Automatic" could skip its own detection encode. It worked for English (454 → 308 ms, same
WER) but wrecked Spanish (21.5 % → 29.4 %): detection off a capped-encoder partial is unreliable,
and taking the last partial instead of the first changed nothing. Reverted — a latency win that
silently degrades one of two supported languages is not a win.

**Spanish is now measured, and Automatic is the wrong default for it.** New corpus:
`qa/wer-fixtures-es.sh` → 15 fixtures / 214 ref words, Spain + Mexico voices, in their own
directory (`qa/fixtures/wer-es/`) with its own manifest and results file — the English generator
wipes its own WAVs, and one mixed manifest would score English-only models against Spanish audio.
`qa/wer.py` now folds diacritics before tokenising (its filter keeps `[a-z0-9:' ]`, so "canción"
was being shattered into "canci n"); folding is symmetric, so a dropped accent is never an error.

| bundled small.bin | WER | mean ASR |
|---|---|---|
| English, Automatic | 1.778 % | 495 ms |
| Spanish, Automatic | 21.495 % | 556 ms |
| Spanish, pinned `es` | **13.551 %** | **344 ms** |
| English, pinned `en` | 1.778 % | 295 ms |
| Spanish on `small.en` (control) | 70.561 % | — |

The control confirms the corpus really measures Spanish. The finding is that **Automatic costs
~160 ms in both languages and ~8 points of WER in Spanish** — pinning the Language menu is better
on both axes. Caveat: fixtures are `say`-synthesized, and synthetic Spanish may detect worse than
a real voice. **Open decision for the user:** leave Automatic as the default (bilingual "just
works", slower, worse Spanish) or default to a pinned language and switch in the menu.

**Swift maths now has tests:** `cadence selftest-stats` — 18 checks over `Stats.compute` (time
saved incl. the never-negative floor, pace ignoring rows without a capture window, streak
counting to the gap and surviving a not-yet-dictated today, range scoping, the 7-bucket chart,
top-app ranking and bar fractions, empty history). All pass; no bug found, but the dashboard's
arithmetic is no longer unpinned. Same pattern as `insertctl selftest`, no XCTest required.

## Systems audit (2026-07-25) — measured, not reviewed

Nine days of real single-user use (49 captures, 40 insertions, `~/.cadence/logs/cadence.log`),
plus a WER re-run and a live AX readback. Three things were wrong; two of them are now fixed.

**1. 35 % of insertions falsely reported failure — FIXED.** 14 of 40 live insertions logged
`clipboard_notify inserted=false verify=contradicted`. Root cause was not timing: the AC-20
readback built `probe = text.suffix(64)` and asked `value.contains(probe)`, an exact substring
match against text the target had already **re-flowed**. Measured with `insertctl read` against a
live Claude Code terminal: Terminal exposes `AXTextArea` = the *visible screen only*, 1 870 chars
over 87 lines wrapped at ~93 columns, continuation lines carrying a `│ ` gutter. A contiguous
64-char probe survives that roughly one time in four — matching the observed hit rate (7/25:
12:50 contradicted, 13:03 contradicted, 13:13 verified). The 0.18 s re-read added 2026-07-19
could never help, because nothing was late.
Four consequences, all silent: the user was told "saved to clipboard" for text that had landed
(double-paste risk); the clipboard was deliberately left stomped (`clipboardRestored=false` is
correct *given* a contradiction); undo was never armed (the core arms only on confirmed
insertion); dashboard time-saved undercounted by ~35 %.
Fix: `foldForReadback` reduces both sides to letters+digits, lowercased, before comparing —
surviving soft wrap, gutters, padding and smart-quote substitution (this machine has smart
quotes on), while a genuine swallow (the Pages page-layout case this check exists for) is still
absent under any folding. Applied to **both** readback sites; `directInsert`'s exact match had
the same flaw, where a false negative is worse — it falls through to paste and the text lands
twice. Pinned by 4 new checks in `insertctl selftest` (9/9), one of which asserts the *old*
exact probe fails on the measured wrapped input. Contradictions now log app + char count +
detail, so the next bad verdict is diagnosable without decrypting history.

**2. The bundled model's accuracy was unmeasured — now measured, and it is the best we have.**
`ggml-small.bin` (multilingual, 488 MB) ships, but §30 had only ever scored `base.en` and
`small.en`. Re-run over the same 15 fixtures / 225 reference words:

| model | WER | mean ASR | max ASR |
|---|---|---|---|
| **ggml-small.bin (bundled)** | **1.778 %** (4/225) | 672 ms | 798 ms |
| ggml-small.en.bin | 3.111 % (7/225) | 639 ms | 769 ms |
| ggml-base.en.bin | 5.778 % (13/225) | 215 ms | 273 ms |

Both previously-recorded numbers reproduced exactly, so the harness is trustworthy. English
accuracy **improved** 1.3 points when bilingual auto-detect landed — the prior assumption that
multilingual would cost English accuracy was wrong. The real cost is latency: the refined pass is
now ~670 ms, so end-to-end (ASR + insertion ≈ 250 ms) exceeds the §28 ≤700 ms p50 budget.
Deliberate trade (accuracy is the daily-use bottleneck) but it should be recorded as a miss, not
as "met". Still open: fixtures are TTS-synthesized (no real-human/accented set), **no Spanish
fixtures at all** despite shipping Spanish, and neither the personal dictionary nor `language=auto`
is covered by the harness.

**3. Test coverage is lopsided where change is fastest — partially addressed.** 6 313 LOC Rust
carries 92 tests; 4 406 LOC Swift (2 892 in the app layer) carries none, because this machine has
Command Line Tools only — no XCTest. That is where every feature of the last two weeks lives.
Interim pattern established here rather than left as a wish: pure logic is exercised through
`insertctl selftest` (now 9 checks), which needs no test target. Still untested: Stats maths
(time-saved, streak, wpm), dashboard filtering, dictionary dedupe.

**Directory-shaped, empty:** `core/dictionary/`, `core/redaction/`, `platform-windows/`, `cloud/`.
The store carries a `redacted` column nothing ever sets true, so "redacted utterances never
retain audio" is a guard that cannot fire — the schema implies a privacy story the code does not
have yet. Local small-LLM cleanup is still the rule engine (ADR-0002).

**Closed by evidence:** the 2026-07-19 route-change capture fix held — 6 lost utterances that
day (`tap install rejected … sampleRate`), **zero since**. Capture start p50 43 ms / p90 79 ms
(§28 ≤50 ms perceived: p50 met), one 330 ms outlier, likely the post-idle-unload reload. No
Cadence crash reports on the machine. AirPods plug/unplug during idle remains the one
never-live-tested recovery path.

## Shipped 2026-07-24 → 25 (five merges)

- **Dashboard v3, native** (`fe77e8f`): value-first layout — time-saved hero, activity chart,
  top apps, streak, wpm; engine latency demoted to a footer. Stats computed Swift-side from
  utterance rows; no aggregation in the core. Brand moved muted-sage → richer green `#3F8A4F` → riso pink + cobalt (29 Oct 2026, brand v1; see docs/brand/README.md)
  (`BrandColor.swift`, icon + overlay regenerated).
- **Runtime language toggle + dashboard v2** (`5cbf29b`): bilingual auto-detect on the
  multilingual model, Language menu (Automatic/English/Spanish), per-decode — no model reload.
- **Personal dictionary** (`b95367b`): terms bias the whisper `initial_prompt`; menu editor.
  "Adesuna" → "Addisuna" verified live.
- **Per-utterance delete + real Re-insert** (`7eb6b7e`): `lastActiveApp` tracking so a past
  dictation can be placed back into the app the user came from.
- **Both ASR passes + add-to-dictionary + focus-aware Re-insert** (`af7e88c`):
  `transcript_instant` was a §24 column nothing ever wrote and the refined pre-cleanup text never
  left the core — `PersistUtterance` now carries `transcript_final`, the router records the last
  streaming partial, both land in their own columns (not `extra_json`), and the dashboard shows
  each pass only when it differs from what was inserted (compared on words, so cleanup's
  punctuation is not reported as disagreement). Selecting text in a transcript adds it to the
  dictionary (button + contextual menu, ≤4 words, case-insensitive dedupe; an open editor absorbs
  the term so Save cannot overwrite it). Re-insert waits for the target to actually own focus
  (poll + 1.5 s deadline → clipboard fallback naming the app) instead of guessing at 0.35 s.
  Also: per-utterance metrics are cleared at capture start — a cancelled utterance never reaches
  persist, so its numbers, and now its partial transcript, rode along on the next record.

**Live checks still owed by the user:** dictionary accuracy with real voice; Re-insert timing and
target; per-utterance delete; and after this batch, whether `verify=contradicted` disappears from
the log during normal terminal dictation (the single number that says finding 1 is closed).

## Resource soak + stall hunt (2026-07-18)

**Idle soak found a real crash.** The resident app had idled 8 h 42 m (natural soak: avg CPU
≈0.008 %, 0 sockets, phys footprint 176–218 MB — CMPRS shows nearly all of it is the
OS-compressed whisper model; RSS settles ~25 MB). Then, ~20 min after a successful live
dictation, the app **aborted on an audio route change**: `AVAudioEngineConfigurationChange` →
observer (on the posting thread, un-debounced) → `teardownTap`+`prewarm` → `installTapOnNode`
raised an ObjC `NSException` mid-reconfiguration → uncatchable in Swift → SIGABRT
(`Cadence-2026-07-18-200950.ips`). Fix (same day):
- `CObjCCatch` target: `CadenceCatchNSException` fences the install; a raise now degrades to
  `CaptureError.tapInstall` (prewarm swallows it; next `start()` rebuilds cold — that
  recovery path already existed). Fence unit-proven (raise caught, clean path nil).
- Route-change rebuild now debounced 150 ms onto the main queue (changes burst on arbitrary
  threads; re-tapping while the engine reconfigures is what raised).
- `ensureTap` also guards `channelCount > 0` (transitional formats can be 48 kHz / 0 ch).
- Not yet re-proven against a real route change — plug/unplug AirPods while idle to confirm.

**Stuck "idle local" pill (user-reported 2026-07-18, screenshot):** core emits
`show_overlay {state: idle}` on return-to-rest paths (cancel, re-enable, error recovery);
the router rendered it as a pill with literal "idle" text and never faded it. Fixed both
layers: router maps idle → immediate fade; `OverlayHUD.show` treats "idle" as dismiss
(belt-and-braces). Needs a live dictation + Esc-cancel to confirm.

**Build-system trap (2026-07-18, found live):** SwiftPM does not track the external
`libcadence_ffi.a` — a rebuilt core with unchanged Swift sources did NOT relink, and
`package-app.sh` shipped a 26-minute-old binary as if new. `build-shell.sh` now deletes the
shell binary when the staticlib is newer, forcing the link. If a core change ever seems to
"not take", check `ls -l target/release/libcadence_ffi.a platform-macos/.build/release/cadence`.

**App identity (2026-07-18):** designed app icon — warm ivory squircle (true Apple
continuous-corner via CALayer `cornerCurve`), five-bar cadence mark in warm ink, gold peak
bar. Source `platform-macos/App/AppIcon/render-icon.swift` (CoreAnimation → 1024 PNG),
`make-icns.sh` → `AppIcon.icns`; package-app.sh bundles it (`CFBundleIconFile`). App pinned
to the Dock (persistent-apps; app stays LSUIElement — Dock tile is a launcher, no running
entry, menu-bar-agent design unchanged). Verified: NSWorkspace resolves the custom icon.

**Metal stall hunt: 10/10 clean.** ~380 headless whisper+Metal decodes (stream_spike partials
×3 audio_ctx + refined, 120 s watchdog, launched non-foreground): zero stalls, refined decode
~113 ms. The one-off 30 s stall did not reproduce headlessly; App Nap on the .app process
remains prime suspect and the activity-assertion mitigation stands.

**Budget verdict (§28 idle):** CPU <1 % PASS (≈0.008 %), network 0 PASS, RAM <150 MB **MISS
by ~26–68 MB**, entirely the resident model (compressed while idle). Confirms the idle
model-unload lever (ADR-0006) is what closes it. Sampler: `qa/soak.sh` →
`qa/soak-results.jsonl` (30 s interval; footprint/CMPRS/RSS/cputime/threads/sockets).

## Phase-0 exit criteria (closed 2026-07-14, except the deferred Windows gate)

| Criterion (§32) | Status |
|---|---|
| Headless core transcribes WAV → cleaned text | ✅ 144 ms warm / 553 ms cold, 282 MB peak (M4, base.en, Metal) |
| Insertion prototype, 0 freezes / 0 corruption | ✅ automated 9/9, 0 freezes, 0 corruption (full table: `qa/matrix-results.jsonl` + git history of this file). Interactive pass 2026-07-16: Spotlight, Pages, Word, VS Code, Messages + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS. Still uncovered: not-installed apps (iTerm2, Cursor, Discord, JetBrains) |
| Windows insertion spike | 🔴 Deferred — no Windows env (ADR-0004); first task when one exists |
| Orchestrator + IPC schema, headless, fully tested | ✅ |
| Golden local model chosen + verified fetch | 🟡 base.en measured via §30 harness: **7.1 % WER, 146.8 ms mean / 206 ms max ASR** (16 TTS fixtures, 225 ref words). Working candidate confirmed by data; final lock still wants a small.en A/B on the same fixtures |

## Phase-1 spine — what works today (2026-07-15)

**Live end-to-end path built:** menu-bar shell (`cadence run`) → Right-Option PTT (CGEvent
tap) → AVAudioEngine capture → FFI ring buffer → whisper.cpp (Metal, worker thread) → rule
cleanup + hallucination guard → real insertion cascade → history JSONL. All driven by the
Phase-0 orchestrator over the new C ABI (ADR-0005).

- **`core/ffi`** (`cadence-ffi`): C ABI + JSON ipc effects; compute effects interpreted
  in-core on core threads; no-lost-words drain contract (`capture_stopped` + 500 ms grace);
  panic-fenced externs. Workspace tests: **50/50** (6 FFI incl. an AC-5 regression test).
- **Swift shell** (`platform-macos`): `CCadenceFFI` (header symlinked from core),
  `CadenceCapture` (16 kHz mono i16 + RMS level), `CadenceHotkeys` (PTT/Esc tap, self-healing),
  `CadenceOverlay` (non-activating NSPanel pill: state glyph, level bars, local chip),
  `cadence` executable (menu-bar agent + effect router + WAV selftest). Build:
  `qa/build-shell.sh`.
- **E2E verification** (`qa/spine-selftest.sh`, run 3× green): WAV injected through the real
  FFI audio path → whisper → cleanup → **direct AX insertion into TextEdit**, readback
  verified, clipboard sentinel restored. **Pipeline 203–233 ms** (3.5 s utterance, model load
  ~180 ms warm), insertion 26–29 ms.
- **Safety, structural:** selftest cannot insert without a frontmost-app guard (default
  TextEdit); the Phase-0 "pasted into WhatsApp" class is closed for all automated runs.

### Fixed this session
- **AC-5 regression (found live):** ring cleared on `StartCapture` raced instant-start audio —
  first 8 000 of 56 235 samples lost, mangling leading words. Clear now happens synchronously
  in `trigger_down` on the caller thread; regression test pins the full window.
- **Overlay level bars invisible (found on first live run):** core emitted `update_waveform`
  correctly (36/utterance, verified via `CADENCE_DEBUG=1` selftest) but the pill's fixed
  260 pt width over-constrained the stack once the bars appeared — AppKit clipped the level
  label. Pill now sizes to content; level label holds a constant 10-glyph width while
  listening so per-chunk updates never relayout.
- **`show_partial` was a stub in the shell router** (previous STATUS claim "shell already
  routes show_partial" was wrong — it parsed but dropped it). Now rendered: instant-pass text
  shows in the pill, head-truncated, and stays up through "thinking" while the refined pass runs.
- **Emoji purge (design rule: no emojis, professional/clean):** overlay glyphs are now
  typographic marks, chip is plain "local"/"cloud", menu-bar icon uses template SF Symbols
  (`mic`/`mic.fill`/…) instead of 🎙/🔴.

### First live mic run (2026-07-15) — PASSED
- Mic TCC granted; 4 dictations, ~90 % word accuracy (user-reported), no freezes.
- Capture start 79–153 ms (85–94 ms warm) — **misses the ≤50 ms perceived target**; needs a
  look (engine pre-warm / keep AVAudioEngine hot between utterances?).
- Insertion live: direct 115 ms once, paste_restore 254–270 ms otherwise (targets non-TextEdit
  apps → cascade fell back as designed); clipboard restored every time.
- Overlay bars/partials were NOT visible on this run — root-caused and fixed above; re-test pending.

## What's stubbed / not started

Superseded in large part — the streaming pass, store, undo, per-app rules, model registry, idle
unload and dictionary all shipped (see the dated sections below and the 7/24–25 list above).
Accurate as of 2026-07-25:

- **Empty directories, no code:** `core/dictionary/` (the shipped dictionary is a whisper-prompt
  bias in the shell, not a crate), `core/redaction/`, `platform-windows/`, `cloud/`.
- **Redaction:** unimplemented; the `redacted` column is never set true.
- **Local small-LLM cleanup:** rule engine still standing in (ADR-0002).
- **Settings UI / onboarding:** everything lives in the menu bar (retention, audio, language,
  dictionary). Adequate for one user; a real Settings window is the gap before a second one.
- **Caret-anchored overlay**, asymmetric model-signature verify (needs a signing key), full
  registry-resolve over FFI, §24 corrections/style/sync tables.
- **Windows everything, cloud everything** (ADR-0004: no Windows environment).

## Current metrics vs targets (§28)

Refreshed 2026-07-25 from 9 days of live logs + the §30 harness on the **bundled** model.

| Metric | Target | Measured |
|---|---|---|
| Local refined-pass pipeline | ≤ 700 ms p50 | **~600 ms end-to-end** (ASR ~500 ms ±50 + insertion ~80 ms on a verifiable target) — target MET after the 7/25 latency pass; was ~913 ms |
| ASR accuracy (§30) | — | **1.778 % WER** bundled multilingual small · 3.111 % small.en · 5.778 % base.en (225 ref words, TTS fixtures). Spanish: 21.5 % on Automatic, **13.6 % pinned** (214 ref words) |
| Insertion engine call | ≤ 250 ms + fallback | 26–29 ms direct AX; **~40–80 ms paste_restore** on verifiable targets (poll, not a flat sleep); opaque targets still 250 ms |
| Insertion outcome (live, 40 real) | inserted, verified | 24 verified · 2 unverifiable · **14 falsely contradicted → root-caused and fixed 7/25** |
| Key-down → capture start | ≤ 50 ms perceived | **p50 43 ms / p90 79 ms / max 330 ms** over 49 live captures — p50 target MET; the tail is likely post-idle-unload reload |
| Active RAM peak | < 1.2 GB | 282 MB (Phase-0 headless, base.en; shell with small.bin unmeasured) |
| Idle RAM / CPU / network | <150 MB / <1% / 0 | **36 MB after unload** (was 177 MB) / ≈0.008 % / 0 sockets — all three MET (`qa/unload-verify.jsonl`) |
| Stability | no crashes | 0 Cadence crash reports on the machine; 6 lost utterances 7/19 (route change), 0 since |

## Open risks (watchlist)
1. **Windows spike unproven** (ADR-0004).
2. **Streaming/instant pass** — DONE for push-to-talk (shared `PartialScheduler`, warmup,
   FFI real-whisper test green, ADR-0006). **Sliding tail window DONE 2026-07-18:** partials
   now decode only the most recent 8 s (`DEFAULT_TAIL_WINDOW_SAMPLES`, `window_start()` in
   both interpreters), and the FFI engine caps the fast-path encoder to match
   (`PARTIAL_AUDIO_CTX_FRAMES` = 512 ≈ 10.2 s coverage). Measured motivation (stream_spike,
   31.6 s WAV): the old growing window collapsed at ~10 s — the capped encoder saw truncated
   mel and produced garbage ("Hello Hello This ThisN also this") at 1.5–2.7 s/partial; the
   pill would have shown nonsense while costs ballooned. With the tail, each partial is
   ≤ 8 s of audio (~100–125 ms observed at that size). Pinned by
   `long_dictation_partials_decode_only_the_tail` (30 s utterance: every partial ≤ tail cap,
   early windows untruncated, refined pass still sees the full utterance exactly once).
   Context carry across the tail boundary deliberately NOT added: partials are display-only
   and head-truncated in the pill; the refined pass is authoritative (§12.3).
3. **One-off 30 s whisper Metal stall** in a backgrounded selftest (1 of ~6 runs, never
   reproduced). Model loaded fine; the *decode* (audio→text) never returned, and the Metal
   crash fired during process-exit cleanup — confirming a decode was still in flight, not a
   load/init fault. Suspected App Nap (run launched from a script with Terminal backgrounded).
   Mitigation in place: ProcessInfo activity assertion during dictation (disables App Nap for
   the dictation window) — plausibly mitigated, NOT confirmed fixed. Containment: not
   word-losing — audio stays in the ring/history path and a hung utterance does not crash the
   hotkey listener. First suspect if any dictation hangs in "thinking". Watch during soak.
4. Direct-AX coverage across Electron/web apps still shallow (falls back to pasteRestore).
5. WER harness (§30) SHIPPED (2026-07-19, `qa/wer.py` + `wer-harness.sh` + `wer-fixtures.sh`,
   results pinned in `qa/wer-results.json`): alignment-based WER/sub/del/ins scoring +
   per-fixture ASR latency, over 15 held-out fixtures (225 ref words). **Re-run 2026-07-25 across
   all three candidates including the bundled model** — see the metrics table; both prior numbers
   reproduced exactly. Remaining caveats: fixtures are **TTS-synthesized** (no real-human or
   accented set), there are **no Spanish fixtures** despite shipping Spanish, and neither the
   personal dictionary nor `language=auto` is covered. Fixture WAVs gitignored; `manifest.tsv`
   ground truth committed.
6. **Latency budget now exceeded by model choice** (§28 ≤700 ms p50): the bundled multilingual
   small decodes in ~670 ms, so "thinking" is ~0.7–0.9 s. Accepted trade for 1.78 % WER. Levers
   if it ever feels slow: `small.en` for English-only users (≈ same latency, worse WER — not a
   lever), `base.en` (3× faster, 3× the errors), or a smaller `audio_ctx` on the refined pass.
7. **Swift layer has no automated tests** (4 406 LOC; no XCTest on this machine). Pure logic is
   reachable via `insertctl selftest`; Stats maths and dashboard filtering remain unpinned.

## Next steps (§32 order)
1. ~~First live `cadence run`~~ ✅ DONE 2026-07-15 (mic granted, ~90 % accuracy). Overlay
   bars+partials fix CONFIRMED live 2026-07-16. ~~Interactive matrix~~ ✅ DONE 2026-07-16
   (agent-driven, idle-gated, focus-guarded): Spotlight, Pages, Word, VS Code, Messages
   + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS, pasteRestore
   297–343 ms, 0 freezes, 0 clipboard corruption, undo verified in Pages/Word/VS Code.
   Slack: deep link to own-user DM + window-title allowlist before pasting. Findings:
   - **Blind-paste gap (release-gate relevant, §30/AC-20):** in Pages with page-layout focus
     (Book template), pasteRestore returned `inserted: true` but the text landed nowhere.
     The engine cannot distinguish "pasted into a text field" from "paste swallowed". Consider
     post-insert verification (AX readback where possible) before reporting success / arming undo.
   - AX-opaque surfaces are common: Spotlight panel, Pages body/template-chooser/save-sheet,
     VS Code editor (role None) — direct AX impossible there; cascade correctly fell back.
   - Spotlight: systemwide AX focus stays on the previous app while the panel is key, so
     insertion works only because synthetic ⌘V routes to the key window.
   - Electron cold start: first paste into a just-launched VS Code fired before the editor had
     keyboard focus (buffer preserved it via hot exit, but timing matters for real dictation).
   - This machine has ⌘Space disabled (symbolic hotkey 64 off) — Spotlight was opened via a
     CGEvent click on the menu-bar icon.
   Resource soak numbers still unmeasured.
1b. **Cadence.app shipped (2026-07-16, e843c18):** real menu-bar app at `~/Applications/Cadence.app`
   (built by `qa/package-app.sh --install`): LSUIElement agent, bundled model (resolution:
   env → bundle → dev path), ad-hoc signed, Accessibility onboarding (prompt + poll, no
   fatalError), mic usage string. New TCC identity ⇒ user must re-grant mic + Accessibility
   to "Cadence" on first launch. Warm capture path landed same commit: tap+converter built
   once (rebuilt on route change), prepare() re-armed after stop, prewarm() at launch —
   expected to cut the 85–94 ms capture start toward ≤50 ms; **needs live re-measure**.
   Engine still fully stops between utterances (mic indicator = actual listening); if still
   over target, next lever is engine.pause() (verify orange dot goes off first).
1c. **Dashboard + observability (2026-07-16, 7424305 + 9ee75dd):** menu → "History &
   Metrics…" — KPI tiles (dictations, words, avg capture start, avg insertion) + history
   table; history.jsonl enriched per utterance (capture_start_ms, capture_window_ms,
   insertion_ms, strategy, frontmost app). Diagnostics tee to `~/.cadence/logs/cadence.log`
   (the .app's stderr is unobservable). **Ad-hoc TCC trap, hit live:** each rebuild's new
   cdhash silently stales the Accessibility grant while the Settings toggle still shows ON —
   toggling does NOT rebind; only `tccutil reset` + fresh grant does. SOLVED (35c1d31):
   `qa/setup-signing.sh` creates the self-signed "Cadence Dev Signing" identity (dedicated
   pre-authorized keychain, user-domain codeSign trust); package-app.sh signs with it, DR =
   identifier + certificate leaf. **Verified live: grants survived a rebuild+reinstall with
   zero re-prompts (2026-07-16 09:51).**
2. ~~Streaming instant-pass ASR spike + wire into live loop~~ ✅ DONE (ADR-0006; shared
   `PartialScheduler`, warmup, FFI real-whisper test green). Shell now renders `show_partial`
   in the pill (was a stub until 2026-07-15). Follow-on: sliding/chunked window with context
   carry for long dictations.
3. Model registry + integrity ✅ DONE (`core/models`: dependency-free SHA-256 + `ModelRegistry`
   verify/golden-rollback §17.5/§29; FFI `cadence_model_verify` gate; ADR-0007). Remaining:
   **idle model unload (<150 MB)** — designed, deferred (tension w/ ~7 s cold load, ADR-0006);
   asymmetric signature verify (needs signing key); full registry-resolve over FFI + a manifest
   in the shell.
4. **Encrypted store SHIPPED (2026-07-18): first §24 slice live.** `core/store`
   (`cadence-store`): SQLCipher via rusqlite `bundled-sqlcipher-vendored-openssl` (no system
   deps, no admin), schema v1 = utterances (full §24 shape + `extra_json` for shell metrics)
   + settings KV + app_rules + models tables, forward-only migrations via `user_version`.
   Key custody: 32-byte random key in the login keychain (`dev.cadence.app`/`store-key`,
   non-synchronizable — local-first), created on first launch by the shell; core sees raw
   bytes only at open (SQLCipher raw-key pragma, no KDF latency). FFI: `cadence_store_open/
   free/persist_json/recent_json/import_jsonl/string_free` (header updated). Shell:
   `HistoryStore.swift`; router persists via store with **JSONL fallback on any failure
   (AC-22 — store is an upgrade, never a gate)**; dashboard reads store-first. One-time
   JSONL import on first launch: **verified live — 19 records imported, JSONL renamed
   `.imported` (kept, not deleted)**. Encryption verified on the live files: 0 plaintext
   hits in db+WAL (plaintext JSONL: 9), header is ciphertext. Wrong key fails closed
   (BadKey), pinned by tests at both the crate and C-ABI layers. Tests 79/79.
   Still §24-open: audio_blobs (audio retention off), dictionary/corrections/style/
   redaction/sync tables, registry `ModelStore` impl over the models table, retention/purge.
   E2E persist of a *new* dictation not yet observed live (user was active; next real
   dictation is the check — `History & Metrics` should show it, and history.jsonl must NOT
   reappear).
5. **Undo + per-app rules + AC-20 verification SHIPPED (2026-07-18):**
   - **Post-insert verification (closes the blind-paste gap):** `InsertionResult` gains
     `verification: verified | unverifiable | contradicted`. pasteRestore reads back the
     focused element AFTER the paste, BEFORE the clipboard restore: a readable value that
     lacks the text tail = `contradicted` → reported as NOT inserted, restore skipped so
     the words stay one ⌘V away (§29), user sees "saved to clipboard". Opaque targets
     (VS Code, web views, Spotlight) stay `unverifiable` and are trusted exactly as before —
     the 6/6 matrix behavior is unchanged. Direct-AX keeps its built-in readback
     (= `verified`). Verification is logged + persisted per utterance (`verification` in
     history extra).
   - **Undo (F21/§26):** ⌃⌥⌘Z global chord (CGEvent tap, consumed) + menu item "Undo Last
     Dictation". Router keeps an `UndoRecord` (app, text, time) written at insert, armed by
     the core's `arm_undo` (fires only on confirmed insertion). Fire guards: armed + idle +
     same app still frontmost (else pill says "switch to X to undo") + ≤2 min fresh; then
     one ⌘Z — insertions land as a single undoable unit (one paste / one AX set), so the
     target reverts exactly that. Standard in-app ⌘Z keeps working independently (§26).
   - **Per-app rules (first slice):** menu toggle "Disable in <frontmost app>" (LSUIElement
     ⇒ opening our menu doesn't steal frontmost; captured in `menuNeedsUpdate`). Persisted
     in the store settings KV (`disabled_apps`, new FFI `cadence_store_setting_get/set`),
     cached in the shell so PTT-down never touches the DB. A swallowed PTT-down also
     swallows its up (no orphan trigger_up). Pill shows "‖ off here", fades.
   - Tests 79/79 (settings KV pinned over the C ABI). LIVE RE-TESTS PENDING: dictate then
     ⌃⌥⌘Z (should revert + "undone" pill); menu toggle in some app then PTT there ("off
     here" pill, no capture); Pages page-layout blind-paste should now report "saved to
     clipboard" instead of a false success.
6. **Idle model unload SHIPPED (2026-07-18):** the ASR worker drops the whisper engine
   (~200 MB model + Metal buffers) after 5 min without ASR work (`CADENCE_UNLOAD_SECS`
   env override; 0 disables) and reloads via a factory on the next dictation — warm-up
   decode re-run, audio_ctx cap re-applied. Reload is worn as a longer "thinking" (~200–
   500 ms warm); capture is unaffected (ring buffers regardless). Reload failure fails
   only that utterance through the existing no-lost-words path (partial jobs release the
   scheduler latch, final jobs → AsrFailed) and retries next time. Regression-pinned:
   `idle_unload_reloads_transparently_on_next_dictation` (1 s unload window, full dictation
   after). 80/80 workspace + 11/11 FFI-whisper. Closes the last §28 idle-budget miss
   **CONFIRMED LIVE (qa/unload-verify.jsonl): 177 MB → 36 MB at exactly the 5-min mark —
   §28 idle budget MET with 4× margin.** All three idle targets now green.
7. **Retention + registry-over-DB (2026-07-18):** `purge_utterances_older_than_days`
   (`retention_days` setting, unset/0 = keep forever; shell runs it at open via
   `cadence_store_purge_utterances`) and `impl cadence_models::ModelStore for Store`
   (schema v2: `models.bundled` column; save is transactional whole-set replace). v1→v2
   migration ran clean on the live store. 82/82. §24 remainder: audio_blobs,
   dictionary/corrections/style/redaction/sync tables; a Settings UI for retention.
8. **audio_blobs SHIPPED (2026-07-19): §24 retained audio, opt-in, off by default.**
   Schema v3 (`audio_blobs`): deliberate deviation from the blueprint sketch — audio is an
   in-row `data BLOB` under the same SQLCipher key, not a `path` to a sidecar file (which
   would need its own encryption + key custody). `secure_delete=ON` at open makes purges
   zero freed pages ("hard delete + secure blob erase", §24). Store API: `put/get/
   delete_audio_blob` + `purge_expired_audio_blobs` (absolute `purge_after` epoch-ms
   deadline stamped at write; NULL = lives and dies with its utterance — the utterance
   retention purge cascades to referenced blobs in one transaction). `UtteranceRecord`
   gains `audio_blob_id` (column existed since v1; now read/written + in record JSON).
   FFI: `cadence_store_audio_put/get/delete/purge_expired` + `cadence_bytes_free`, header
   updated. Shell: menu toggle "Keep Audio Recordings" (`retain_audio` setting, cached —
   PTT never touches the DB); router tees capture chunks into a lock-guarded per-utterance
   accumulator (armed before tap start, cleared on cancel/discard), `persist_utterance`
   hands samples to `HistoryStore` which writes a 16 kHz mono WAV (`WavWriter`, canonical
   44-byte header, no AVFoundation) blob then links it in the record. Blob deadline:
   `audio_retention_days` setting wins, else `retention_days`, else none; expired-blob
   purge runs at every launch. Audio is best-effort: blob failure keeps the transcript
   (AC-22); redacted utterances never retain audio; audio never goes to the JSONL
   fallback. Tests 86/86 (blob roundtrip+link, expiry purge + ref-clearing, retention
   cascade, v2→v3 forward migration, full C-ABI roundtrip). dist/Cadence.app repackaged —
   v2→v3 migration will run on next launch of the installed app. LIVE CHECKS PENDING:
   toggle "Keep Audio Recordings", dictate, confirm a WAV-shaped blob row + linked
   `audio_blob_id` in history; playback UI is future work (dashboard doesn't surface
   audio yet). §24 remainder: dictionary/corrections/style/redaction/sync tables; a
   Settings UI for retention windows.
9. **Daily-driver hardening (2026-07-19, b5439a7):** push toward "casual daily use".
   - **Model tier decision (§30):** WER harness re-run — small.en 3.11% vs base.en 5.78%
     (225 ref words), refined ~350-450 ms / partials ~270-420 ms on M4 (vs base's ~115 ms
     refined). Accuracy is the daily-use bottleneck (~90% felt), so **small.en is now the
     bundled model**; base.en remains the §17.5 golden rollback. Both sha256-pinned in
     fetch-models.sh. Idle unload caps the RAM cost (bigger model only resident while
     dictating + 5 min).
   - **Static-link fix (shipped-app integrity):** cadence-ffi built cdylib+staticlib; the
     Swift linker preferred the dylib and bound the installed app to the ABSOLUTE dev-tree
     path — any `cargo build` without `--features whisper` silently broke the installed
     app ("built without the whisper feature", hit live). crate-type is now staticlib+rlib
     only; verified 0 dylib refs, whisper symbols in-binary.
   - **Quit SIGABRT fixed (every quit crashed):** ggml Metal teardown asserts in atexit if
     the device is alive at exit; engine freed before NSApp.terminate (menu quit +
     applicationWillTerminate for ⌘Q/AppleScript). Verified live: clean quit, no new .ips.
   - **Route-change capture failure fixed (hit live 7/19 10:43):** after a route change
     the retry used inputNode's stale sample rate. start() hard-resets the engine before
     retrying; ensureTap re-validates the installed tap's format against hardware.
     AirPods plug/unplug while idle remains the live confirmation.
   - **Menu:** "Start at Login" (SMAppService.mainApp) + "Keep History" retention submenu
     (Forever/90/30/7; purge applies immediately on shortening).
   86/86 + 11/11 whisper-FFI. Repackaged + reinstalled with small.en; launch "core ready"
   221-376 ms. LIVE CHECKS PENDING (Daniel): dictation accuracy feel on small.en; latency
   feel (thinking is ~250-450 ms now); AirPods route change; Keep Audio Recordings blob
   write; Start at Login across a reboot.
5. Windows environment → port insertion spike + this FFI (header already C-clean).

## HARD STOP receipt — 2026-11-01

Stopped immediately on fresh dashboard five-hour5%, weekly9%. Previous fresh read was
five-hour9%, weekly10%; the next read crossed the user-authorized7% stop before it was
observed. Do not claim an exact7% stop. No reset, credit purchase or limit change.
Read-only PR75 CI watcher stopped; no automatic merge is queued.

Installed app0.1.4(7) IS running and verified, source742e224 in~/cadence-single-tap.
Single-tap finish, input/filter status and visible version are live. Hotkeys74/delivery20/
insertion9/packaging5 and optimized build pass; rollback preserved. PR75 pushed/reviewed,
last observed native CI still pending. Last attempted conditional merge exited on pending
checks; NO Step10 merge todev/main or release PR is claimed. Do not infer later CI state.
UPDATE (Claude, later 2026-11-01): PR75 CI was green (cargo-test, site-and-release);
squash-merged to dev as baa6d5f, feature branch deleted. Step 11 continues on
fix/forgiving-double-tap.

NEXT after allowance permits: check actualPR75 CI, squash merge/delete feature if green;
create dev→main release PR listing#75, post Codex review, awaitCI, merge without deletingdev.
Keep local STATUS checkpoints and research notes. Then investigate music/noise route
(answer to earbuds/headphones vs speakers still pending), safe processing lifecycle and
consented quiet/music benchmark. Noise suppression itself remains unchanged/unfixed.
Full receipt~/cadence-single-tap/dist/controls-install-receipt.json and doctor.json.
Normal reserve is10%;7% was Daniel's explicit exception for this pass.
