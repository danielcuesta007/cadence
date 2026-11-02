# ADR-0009: Extension points for optional add-ons

**Status:** proposed (design pass) · 2026-11-02 · Step 18 · follows ADR-0008, checkpoint 4

Naming a future step here does not authorize it. This ADR adds a trait and an empty registry
only. It adds no paid feature, no licence check, no payment code and no network calls.

## Context

ADR-0008 chose open core: paid extras live in a separate private repository that depends on
the free core, never the reverse, and the free build must compile and pass its tests without
them. The core needs a seam for that before any extra exists, so the rule can be tested from
the first commit instead of retrofitted. Candidate extras (ideas, not promises): sync across
Macs (blueprint §7.6), team and admin controls (§7.7), and file and meeting transcription (§34).

## Decision

A new crate, `core/extensions` (`cadence-extensions`), with **no dependencies**:

- `trait Extension: Send` with `id()` and hooks that all default to no-ops. The first and only
  hook is `on_dictation_finished(&FinishedDictation)`: the cleaned text, its language, and
  whether it was inserted.
- `struct Registry` holding the extensions a build ships with. `Registry::default()` is empty,
  and that empty registry is the free build. Duplicate ids are refused.

Rules:

1. **One-way dependency.** Add-ons depend on `cadence-extensions`; no workspace crate depends
   on an add-on. A test reads every member's `Cargo.toml` and fails on a `git =` dependency or
   a `path =` dependency outside the repo.
2. **Observe only.** Hooks run after the text is delivered. They cannot change the text, block
   insertion or add latency to the dictation path. A missing or failing add-on never degrades
   the free app.
3. **Zero extensions is the tested default.** A test runs a full dictation (PCM to orchestrator
   to ASR to cleanup to insertion) with an empty registry, in `cargo test --workspace` on CI.
4. **Privacy stays in the core.** Nothing here opens a connection, reads an account or checks a
   licence. If a paid build ever checks a licence, it does so offline, in the add-on.

### Not wired yet (deliberately)

The registry is not yet called from `cadence-ffi` or the orchestrator. Wiring happens when the
first real add-on exists (checkpoint 4 proper), so the hook shapes come from a real need rather
than a guess. The likely shapes:

| Candidate extra | Hook it would need |
|---|---|
| Sync across Macs (§7.6) | `on_dictation_finished` plus history-entry events from `cadence-store` |
| Team and admin controls (§7.7) | a read-only settings-policy provider the shell consults |
| File and meeting transcription (§34) | a separate input source feeding the same ASR engine |

Each new hook gets a no-op default so existing add-ons keep compiling.

## Consequences

- The free build stays exactly as it was: nothing registers, and nothing calls the registry yet.
- The private repo, when it exists, adds `cadence-extensions` as a git dependency on the public
  core and implements `Extension`. The public repo never names it.
- Cost: one small std-only crate and two tests.

## Reversibility

Very high. Delete the crate and its workspace entry; nothing else references it.
