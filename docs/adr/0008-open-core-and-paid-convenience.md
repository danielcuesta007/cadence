# ADR-0008: Business model — open core plus a paid convenience build

**Status:** accepted (direction) · 2026-11-02 · decided by Daniel

Daniel, verbatim: "i like doing the open core, and seleign conveinc ideas".

Not legal advice. Take the open questions below to the ND IDEA Center (free) or a startup
lawyer before charging money. Naming a future step here does not authorize it.

## Context

- Cadence is public on GitHub under MIT. Daniel is the only author (all 138 commits as of
  2 Nov 2026), so he alone can license future versions differently.
- Every third-party component allows commercial use (Whisper and whisper.cpp MIT,
  whisper-rs Unlicense, SQLCipher BSD-style, OpenSSL Apache 2.0; see
  `THIRD_PARTY_NOTICES.md` and `docs/legal/READINESS.md`).
- Versions already published stay MIT forever. Anyone who has a copy may keep using,
  changing and even selling those exact versions. As of 2 Nov 2026: 27 DMG downloads across
  v0.1.0 to v0.1.6, 173 unique cloners in 14 days (mostly automated: CI, worktrees,
  mirrors), 0 forks, 0 stars.
- "Open source, on-device" is part of Daniel's public story: the site, the résumé, the
  profile README, and the TreeHacks 2027 application all link the public repo.

Options weighed (2 Nov 2026): going fully private, a source-available licence for future
versions (FSL or BSL), open core, and selling a convenience build of the open code.
Going private breaks the installer and Homebrew cask (they download from GitHub Releases),
removes the profile pin and contradicts the TreeHacks application. A source-available
switch is legal but changes the open-source story. Open core and a paid convenience build
keep every public link working.

## Decision

Two paid layers on top of a free, MIT, public core.

1. **Free core stays MIT and public.** Dictation in any app, on-device recognition, both
   language keys, encrypted history, the current feature set and every future fix to them.
   The core must be useful on its own, not a demo.
2. **Paid convenience build ("selling convenience").** Same code, sold for what it saves:
   signed and notarized by Apple (no Open Anyway step), automatic updates, and direct
   support. People who build from source still get it free.
3. **Paid features ("open core").** New features that are clearly extra live in a separate
   private repo that builds on the public core. Candidates only, none committed:
   encrypted sync across Macs (blueprint §7.6), team and admin controls (§7.7), and meeting
   and file transcription (§34). Anything already shipped free stays free (for example the
   noisy-room setting from Step 15).

### Rules that keep it honest

- **Never paywall privacy or offline use.** No network calls, accounts or telemetry are added
  to the free core to enforce payment. A licence check, if any, works offline.
- **One-way dependency.** The private repo depends on the public core, never the reverse.
  Paid features plug in through traits in the core, so the free build compiles and passes
  its tests without them.
- **Contributions.** Before the first outside pull request is accepted, add a contributor
  agreement (CLA, or DCO plus a licence grant) so Daniel keeps the right to ship paid
  builds that include that work.

## Order of work (gates, not dates)

The public version of these gates and of the free-forever list is the site's Promises page,
`site/promises.html` (https://cadence-dictation.pages.dev/promises). A site test fails if its
"Free forever" list loses an item; change both together.

1. **Keep the repo public and MIT through TreeHacks 2027** (decisions late December 2026,
   event 12–14 Feb 2027). The application links the repo and calls it open source.
2. **Clear the open questions in `docs/legal/READINESS.md` before taking money:** the name
   (Cadence Design Systems owns CADENCE for software), Notre Dame IP confirmation, an LLC,
   and a merchant of record (Lemon Squeezy or Paddle) for sales tax.
3. **Apple Developer Program ($99 a year) and notarization**, then switch the site's
   "why it isn't notarized" copy to explain the free and paid builds.
4. **Carve the plug-in boundary** in the core (traits only, no paid code) and create the
   private repo for the first paid feature.
5. **Ship the paid build** through the merchant of record. The free DMG and Homebrew cask
   keep downloading from GitHub Releases unchanged.

## Consequences

- Public links, the installer, the cask and the profile pin keep working.
- The free app and the paid build must both stay tested. CI covers the free core alone.
- Anyone may legally sell their own build of the MIT core. The paid build has to win on
  convenience, trust and support, not on exclusivity of the core code.

## Reversibility

High while nothing is sold. Later moves stay possible: the core could adopt a
source-available licence for future versions, or the whole project could go private
(move the DMG hosting off GitHub Releases first). Versions already published stay MIT
whatever happens.
