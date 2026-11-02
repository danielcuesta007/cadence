//! cadence-asr — local ASR runtime bindings (§17.1).
//!
//! Phase 0: [`AsrEngine`] trait + a deterministic mock (for headless orchestrator tests) and a
//! whisper.cpp-backed engine behind the `whisper` feature (ADR-0003). The streaming
//! instant-pass API lands in Phase 1; Phase 0 covers the refined pass (WAV window → text).

use cadence_ipc::Transcript;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AsrError {
    #[error("no speech detected")]
    Empty,
    #[error("asr engine failed: {0}")]
    Engine(String),
}

pub trait AsrEngine {
    /// Refined (final) pass over a complete utterance window. 16 kHz mono f32 PCM in [-1, 1].
    fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError>;

    /// Instant pass (§12.3 strategy B): a fast, low-latency decode over the audio captured
    /// *so far* — called repeatedly on a growing window while the user is still speaking, to
    /// surface a live partial. Returns a [`Transcript`] whose `instant` carries the partial
    /// text; `refined` mirrors it for callers that ignore the split. Accuracy is traded for
    /// latency, so the refined [`transcribe`](AsrEngine::transcribe) pass is still authoritative.
    ///
    /// Default impl delegates to `transcribe` and relabels the output as instant, so engines
    /// without a dedicated fast path stay correct (just not fast).
    fn transcribe_partial(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        let t = self.transcribe(pcm)?;
        Ok(Transcript {
            instant: Some(t.refined.clone()),
            refined: t.refined,
            language: t.language,
        })
    }

    /// Drop any per-utterance streaming state carried across [`transcribe_partial`] calls, so
    /// the next utterance's instant pass starts clean. Default no-op for stateless engines.
    fn reset_stream(&mut self) {}

    /// Set the decode language: "auto" (detect per utterance, multilingual models only) or an
    /// ISO code like "en"/"es". Cheap — language is a per-decode parameter, not baked into the
    /// loaded model, so this takes effect on the next `transcribe`. Default no-op for engines
    /// (like the mock) that don't decode. Empty string is ignored by convention.
    fn set_language(&mut self, _lang: &str) {}

    /// Bias decoding toward a set of terms the user cares about (proper nouns, jargon, names)
    /// — whisper's `initial_prompt` mechanism (§ personal dictionary). The prompt is a plain
    /// phrase/list; empty clears it. Takes effect on the next refined `transcribe`. Default
    /// no-op for engines that don't decode.
    fn set_prompt(&mut self, _prompt: &str) {}

    /// Noisy-room mode (Step 16): beam search on the refined pass, which measured ~22 % fewer
    /// errors with background voices at speaker level but ~70 % more decode time. Opt-in from
    /// the menu; takes effect on the next refined `transcribe`. Default no-op for engines that
    /// don't decode.
    fn set_noisy_room(&mut self, _on: bool) {}
}

/// Deterministic mock for tests and for machines without a model present.
pub struct MockAsr {
    pub refined: String,
}

impl AsrEngine for MockAsr {
    fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        if pcm.is_empty() {
            return Err(AsrError::Empty);
        }
        Ok(Transcript {
            instant: None,
            refined: self.refined.clone(),
            language: Some("en".into()),
        })
    }
}

/// Convert interleaved i16 PCM to the f32 format the engines expect.
pub fn pcm_i16_to_f32(samples: &[i16]) -> Vec<f32> {
    samples.iter().map(|&s| s as f32 / 32768.0).collect()
}

#[cfg(feature = "whisper")]
pub mod whisper {
    use super::{AsrEngine, AsrError};
    use cadence_ipc::Transcript;
    use whisper_rs::{
        FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState,
    };

    pub struct WhisperAsr {
        ctx: WhisperContext,
        threads: i32,
        /// Reusable decode state for the instant pass, created lazily and kept alive across a
        /// stream so we pay `whisper_init_state` (KV-cache alloc) once per utterance, not per
        /// partial. Cleared at utterance boundaries via [`reset_stream`](WhisperAsr::reset_stream).
        partial_state: Option<WhisperState>,
        /// Encoder context length for the instant pass (§12.3). 0 = model default (1500 frames
        /// for base = 30 s). Shrinking it caps the encoder cost on short windows — the same knob
        /// whisper.cpp's `stream` example exposes as `--audio-ctx`. Must stay ≥ the window's own
        /// frame count (~50 frames/s) or trailing audio is truncated.
        partial_audio_ctx: i32,
        /// Decode language passed to whisper. "auto" lets whisper detect the spoken language
        /// per utterance (multilingual models only) — this is what makes bilingual dictation
        /// "just work". An explicit ISO code ("en", "es") pins it. Resolved once from
        /// `CADENCE_LANG` at load; see [`resolve_language`].
        lang: String,
        /// Personal-dictionary bias (§): fed to whisper as `initial_prompt` on the refined pass
        /// so proper nouns / jargon the user added decode with the right spelling. Empty = no
        /// bias. Set by the shell from the stored vocabulary.
        prompt: String,
        /// Noisy-room mode: beam search on the refined pass (see `refined_beam`).
        noisy_room: bool,
    }

    /// Encoder frames per second of audio: whisper's mel is 100 fps, and the encoder's first
    /// conv layer strides by 2.
    const ENCODER_FRAMES_PER_SEC: f32 = 50.0;
    /// Full encoder context — 30 s, what the model was trained at.
    const FULL_AUDIO_CTX: i32 = 1500;
    /// Headroom over the audio's own frame count. The encoder must see past the last frame of
    /// speech (trailing context is what lets it finish a word), and detection of a stray frame
    /// boundary should never clip the tail.
    const REFINED_CTX_MARGIN: i32 = 128;
    /// Never shrink below this. Sizing the window to the audio is *not* free: the model has only
    /// ever seen full-length positional embeddings, so a short window degrades accuracy even
    /// when it covers every frame of speech. Measured on the §30 fixtures (bundled small, 225
    /// ref words, 2026-07-25) — the cliff is steep and 1280 is the knee:
    ///
    /// | audio_ctx | WER | mean ASR |
    /// |---|---|---|
    /// | 1500 (full) | 1.778 % | 642 ms |
    /// | **1280** | **1.778 %** | **566 ms** |
    /// | 1024 | 2.222 % | 556 ms |
    /// | 768 | 3.556 % | 503 ms |
    /// | sized-to-audio (~384) | 4.000 % | 458 ms |
    ///
    /// Accuracy is the daily-use bottleneck, so we take only the free 12 % and stop.
    const MIN_REFINED_CTX: i32 = 1280;

    /// Encoder context for a refined decode of `samples` at 16 kHz.
    ///
    /// Whisper always encodes a 30 s mel, padding a 4 s utterance with 26 s of silence and paying
    /// full encoder cost for it. Trimming `audio_ctx` (the knob whisper.cpp's `stream` example
    /// exposes) reclaims some of that — but only down to [`MIN_REFINED_CTX`], below which
    /// accuracy falls off a cliff. Long utterances still grow the window to cover their own
    /// audio: truncating real speech is the one thing this must never do.
    ///
    /// `CADENCE_REFINED_CTX` overrides: a frame count pins it, `0` restores the full 30 s
    /// encoder (the pre-2026-07-25 behaviour) for A/B measurement.
    fn refined_audio_ctx(samples: usize) -> i32 {
        if let Some(v) = std::env::var("CADENCE_REFINED_CTX")
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok())
        {
            return v.clamp(0, FULL_AUDIO_CTX);
        }
        let secs = samples as f32 / 16_000.0;
        let needed = (secs * ENCODER_FRAMES_PER_SEC).ceil() as i32 + REFINED_CTX_MARGIN;
        needed.clamp(MIN_REFINED_CTX, FULL_AUDIO_CTX)
    }

    /// Refined-pass sampling. Greedy by default (the measured latency/accuracy point); the
    /// opt-in noisy-room mode switches to beam search (see [`super::refined_beam`]), and
    /// `CADENCE_BEAM=<n>` still overrides for A/B measurement (qa/noise-bench.sh).
    fn refined_strategy(noisy_room: bool) -> SamplingStrategy {
        let env = std::env::var("CADENCE_BEAM").ok();
        match super::refined_beam(env.as_deref(), noisy_room) {
            Some(beam_size) => SamplingStrategy::BeamSearch {
                beam_size,
                patience: -1.0,
            },
            None => SamplingStrategy::Greedy { best_of: 1 },
        }
    }

    /// `1`/`true`/`on` → true; anything else (or unset) → false. A/B switches only.
    fn env_flag(name: &str) -> bool {
        super::parse_flag(std::env::var(name).ok().as_deref())
    }

    /// Language for the decode: `CADENCE_LANG` if set (e.g. "es" to force Spanish, "en" to
    /// force English), otherwise "auto" so whisper detects it from the audio. Auto-detection
    /// requires a multilingual model — the English-only `.en` tiers ignore it and stay English.
    fn resolve_language() -> String {
        std::env::var("CADENCE_LANG")
            .ok()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "auto".into())
    }

    impl WhisperAsr {
        pub fn load(model_path: &str) -> Result<Self, AsrError> {
            let mut cparams = WhisperContextParameters::default();
            // Flash attention: a fused attention kernel, mathematically the same result with a
            // smaller memory footprint — pure latency, no accuracy cost (verified against the
            // §30 harness, not assumed). Off by default in whisper-rs; we opt in.
            // `CADENCE_FLASH_ATTN=0` disables it for A/B measurement.
            cparams.flash_attn = std::env::var("CADENCE_FLASH_ATTN")
                .ok()
                .map(|v| v.trim() != "0")
                .unwrap_or(true);
            let ctx = WhisperContext::new_with_params(model_path, cparams)
                .map_err(|e| AsrError::Engine(format!("model load: {e}")))?;
            let threads = std::thread::available_parallelism()
                .map(|n| (n.get() as i32).min(8))
                .unwrap_or(4);
            Ok(Self {
                ctx,
                threads,
                partial_state: None,
                partial_audio_ctx: 0,
                lang: resolve_language(),
                prompt: String::new(),
                noisy_room: false,
            })
        }

        /// Cap the instant-pass encoder length (frames; ~50 per second of audio). 0 restores the
        /// model default. Callers should size this to their rolling-window cap.
        pub fn set_partial_audio_ctx(&mut self, frames: i32) {
            self.partial_audio_ctx = frames;
        }

        /// What to record as the utterance's language. A pinned code is reported as-is; "auto"
        /// leaves it unknown (whisper detected it internally, but we don't surface the id here).
        fn reported_language(&self) -> Option<String> {
            if self.lang == "auto" {
                None
            } else {
                Some(self.lang.clone())
            }
        }
    }

    /// Low-latency instant-pass params. Free function (not a method) so it borrows nothing from
    /// `WhisperAsr` — otherwise the returned [`FullParams`] would pin an immutable borrow of
    /// `self` that collides with the `&mut partial_state` the decode needs.
    fn fast_params<'a>(threads: i32, audio_ctx: i32, lang: &'a str) -> FullParams<'a, 'a> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(threads);
        params.set_language(Some(lang));
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        // Instant-pass shortcuts: one segment, no cross-window prompt, capped encoder.
        params.set_single_segment(true);
        params.set_no_context(true);
        if audio_ctx > 0 {
            params.set_audio_ctx(audio_ctx);
        }
        params
    }

    impl AsrEngine for WhisperAsr {
        fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
            if pcm.is_empty() {
                return Err(AsrError::Empty);
            }
            let mut state = self
                .ctx
                .create_state()
                .map_err(|e| AsrError::Engine(format!("state: {e}")))?;
            let mut params = FullParams::new(refined_strategy(self.noisy_room));
            params.set_n_threads(self.threads);
            params.set_language(Some(&self.lang));
            if env_flag("CADENCE_SUPPRESS_NST") {
                params.set_suppress_nst(true);
            }
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_suppress_blank(true);
            // Personal-dictionary bias: proper nouns/jargon spell correctly (§). Refined pass
            // only — the instant pass stays lean, and the refined text is authoritative.
            if !self.prompt.is_empty() {
                params.set_initial_prompt(&self.prompt);
            }
            // Encode only as much context as the audio occupies (see `refined_audio_ctx`).
            let ctx_frames = refined_audio_ctx(pcm.len());
            if ctx_frames > 0 && ctx_frames < FULL_AUDIO_CTX {
                params.set_audio_ctx(ctx_frames);
            }
            state
                .full(params, pcm)
                .map_err(|e| AsrError::Engine(format!("decode: {e}")))?;
            let refined = collect_text(&state);
            if refined.is_empty() {
                return Err(AsrError::Empty);
            }
            Ok(Transcript {
                instant: None,
                refined,
                language: self.reported_language(),
            })
        }

        fn transcribe_partial(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
            if pcm.is_empty() {
                return Err(AsrError::Empty);
            }
            if self.partial_state.is_none() {
                self.partial_state = Some(
                    self.ctx
                        .create_state()
                        .map_err(|e| AsrError::Engine(format!("partial state: {e}")))?,
                );
            }
            let params = fast_params(self.threads, self.partial_audio_ctx, &self.lang);
            let state = self.partial_state.as_mut().expect("state just ensured");
            state
                .full(params, pcm)
                .map_err(|e| AsrError::Engine(format!("partial decode: {e}")))?;
            let text = collect_text(state);
            if text.is_empty() {
                return Err(AsrError::Empty);
            }
            Ok(Transcript {
                instant: Some(text.clone()),
                refined: text,
                language: self.reported_language(),
            })
        }

        fn reset_stream(&mut self) {
            self.partial_state = None;
        }

        fn set_language(&mut self, lang: &str) {
            let lang = lang.trim();
            if !lang.is_empty() {
                self.lang = lang.to_lowercase();
            }
        }

        fn set_prompt(&mut self, prompt: &str) {
            self.prompt = prompt.trim().to_string();
        }

        fn set_noisy_room(&mut self, on: bool) {
            self.noisy_room = on;
        }
    }

    fn collect_text(state: &WhisperState) -> String {
        let mut out = String::new();
        for segment in state.as_iter() {
            if let Ok(text) = segment.to_str() {
                out.push_str(text);
            }
        }
        // Noise makes whisper caption the room instead of the speaker ("[indistinct chatter]",
        // "(music)") — never words the user said, so they must not be typed into their document.
        // `CADENCE_KEEP_CAPTIONS=1` keeps them, for before/after measurement only.
        if super::parse_flag(std::env::var("CADENCE_KEEP_CAPTIONS").ok().as_deref()) {
            return out.trim().to_string();
        }
        super::strip_non_speech(&out)
    }
}

/// Sound words: a `(...)`/`*...*` span must contain at least one of these to be a caption.
const CAPTION_SOUNDS: &[&str] = &[
    "music", "laugh", "laughs", "laughing", "laughter", "applause", "clapping", "cheering",
    "chatter", "chattering", "inaudible", "indistinct", "unintelligible", "silence", "cough",
    "coughs", "coughing", "sigh", "sighs", "sniffs", "mumbling", "mumbles", "crosstalk",
    "blank_audio", "humming", "beep", "beeping", "whispering", "whispers", "noise", "noises",
];

/// Words allowed alongside a sound word in a caption ("upbeat music", "speaking in foreign
/// language", "crowd chattering"). EVERY word of a `(...)`/`*...*` span must be a sound or one of
/// these — so "(talking points)", "(background)" and "(foreign policy)" stay as the user's text.
const CAPTION_MODIFIERS: &[&str] = &[
    "upbeat", "soft", "gentle", "dramatic", "loud", "light", "quiet", "background", "crowd",
    "audience", "people", "speaking", "talking", "in", "a", "foreign", "language", "and",
    "playing", "continues", "plays", "static", "electronic", "piano", "guitar", "instrumental",
];

/// Whole captions whisper emits that carry no sound word.
const CAPTION_PHRASES: &[&str] = &[
    "speaking in foreign language",
    "speaking foreign language",
    "foreign language",
    "no speech",
];

/// Remove whisper's non-speech captions from a transcript (Step 15, noise in loud rooms).
///
/// - `[...]`: whisper's caption convention ("[BLANK_AUDIO]", "[Music]", "[indistinct chatter]").
///   Removed when non-empty, letters/spaces/`_`/`-` only and at most six words — anything with
///   digits or symbols ("[0]", "[TODO: x]") stays.
/// - `(...)` and `*...*`: removed only when every word is caption vocabulary and at least one is
///   a sound ([`CAPTION_SOUNDS`], [`CAPTION_MODIFIERS`]): "(upbeat music)", "*laughs*" go;
///   "(talking points)", "(see appendix)", "init()", "**bold**" stay.
/// - `♪ ... ♪` / `♫`: lyrics transcribed off background music; the span and stray notes go.
///
/// Text with no caption is returned exactly as before this filter existed (only trimmed): the
/// user's own spacing, newlines and leading punctuation (".5 mg") are never touched. Tidying runs
/// only around a removed span. A transcript that was nothing but captions comes back empty, which
/// callers already treat as "no speech".
pub fn strip_non_speech(text: &str) -> String {
    fn word_key(w: &str) -> String {
        w.trim_matches(|c: char| !c.is_alphanumeric() && c != '_').to_lowercase()
    }
    fn plain(inner: &str) -> bool {
        inner
            .chars()
            .all(|c| c.is_alphabetic() || c.is_whitespace() || c == '_' || c == '-' || c == '\'')
    }
    fn square_caption(inner: &str) -> bool {
        let n = inner.split_whitespace().count();
        (1..=6).contains(&n) && plain(inner)
    }
    fn sound_caption(inner: &str) -> bool {
        let words: Vec<String> = inner.split_whitespace().map(word_key).collect();
        if words.is_empty() || words.len() > 6 || !plain(inner) {
            return false;
        }
        if CAPTION_PHRASES.contains(&words.join(" ").as_str()) {
            return true;
        }
        let known = |w: &String| {
            CAPTION_SOUNDS.contains(&w.as_str()) || CAPTION_MODIFIERS.contains(&w.as_str())
        };
        words.iter().all(known) && words.iter().any(|w| CAPTION_SOUNDS.contains(&w.as_str()))
    }

    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut dropped = false;
    let mut dropped_at_start = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let close = match c {
            '[' => Some(']'),
            '(' => Some(')'),
            '*' => Some('*'),
            '\u{266A}' | '\u{266B}' => Some(c),
            _ => None,
        };
        if let Some(close) = close {
            let span_end = chars[i + 1..].iter().position(|&x| x == close);
            let drop_len = match (c, span_end) {
                (_, Some(off)) => {
                    let inner: String = chars[i + 1..i + 1 + off].iter().collect();
                    let is_caption = match c {
                        '[' => square_caption(&inner),
                        '(' | '*' => sound_caption(&inner),
                        _ => true, // ♪ lyrics ♪
                    };
                    is_caption.then_some(off + 2)
                }
                ('\u{266A}' | '\u{266B}', None) => Some(1),
                _ => None,
            };
            if let Some(len) = drop_len {
                if out.trim().is_empty() {
                    dropped_at_start = true;
                }
                dropped = true;
                // Close only the gap this caption leaves (issue #95): spaces/tabs on both sides
                // go, then one space rejoins the halves unless a line break or closing
                // punctuation already separates them. Everything else stays as dictated.
                while out.ends_with([' ', '\t']) {
                    out.pop();
                }
                let mut j = i + len;
                while j < chars.len() && matches!(chars[j], ' ' | '\t') {
                    j += 1;
                }
                let next = chars.get(j).copied();
                if out.ends_with('\n') && next == Some('\n') {
                    j += 1; // "line one\n[Music]\nline two" keeps one line break, not two
                }
                let joins = !out.is_empty()
                    && !out.ends_with('\n')
                    && !matches!(next, None | Some('\n' | ',' | '.' | '!' | '?' | ';' | ':'));
                if joins {
                    out.push(' ');
                }
                i = j;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }

    if !dropped {
        return text.trim().to_string();
    }
    let tidy = out.trim();
    if dropped_at_start {
        // "[Music], send it" → "send it": only when the caption itself opened the text.
        tidy.trim_start_matches([',', '.', ';', ':']).trim().to_string()
    } else {
        tidy.to_string()
    }
}

/// Beam width from a `CADENCE_BEAM` value: `Some(n)` for n >= 2 (capped at 8), `None` (greedy)
/// for unset, garbage, 0 or 1.
pub(crate) fn parse_beam(v: Option<&str>) -> Option<i32> {
    match v?.trim().parse::<i32>().ok()? {
        n if n >= 2 => Some(n.min(8)),
        _ => None,
    }
}

/// Beam width the noisy-room mode uses: the width qa/noise-bench.sh measured in Step 15
/// (babble at speaker level: 17.8 % → ~13.9 % WER; one extra error on quiet audio).
pub const NOISY_ROOM_BEAM: i32 = 5;

/// Refined-pass beam width: an explicit `CADENCE_BEAM` (n >= 2) wins, for A/B measurement;
/// otherwise noisy-room mode means [`NOISY_ROOM_BEAM`], and off means greedy (`None`).
pub(crate) fn refined_beam(env: Option<&str>, noisy_room: bool) -> Option<i32> {
    parse_beam(env).or(noisy_room.then_some(NOISY_ROOM_BEAM))
}

/// A/B switch value: `1`/`true`/`on` (any case) → true, everything else → false.
pub(crate) fn parse_flag(v: Option<&str>) -> bool {
    v.map(|v| matches!(v.trim().to_lowercase().as_str(), "1" | "true" | "on"))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captions_are_stripped() {
        assert_eq!(strip_non_speech("[indistinct chatter]"), "");
        assert_eq!(strip_non_speech(" [BLANK_AUDIO]"), "");
        assert_eq!(strip_non_speech("(upbeat music)"), "");
        assert_eq!(
            strip_non_speech("[Music] Send the invoice by Friday."),
            "Send the invoice by Friday."
        );
        assert_eq!(
            strip_non_speech("Send it (laughs) by Friday, okay?"),
            "Send it by Friday, okay?"
        );
        assert_eq!(strip_non_speech("Sure *coughs* that works."), "Sure that works.");
        assert_eq!(strip_non_speech("Hello [crowd noise], team."), "Hello, team.");
        assert_eq!(strip_non_speech("\u{266A} la la love \u{266A} Call me."), "Call me.");
        assert_eq!(strip_non_speech("Done \u{266B}"), "Done");
    }

    #[test]
    fn real_text_in_brackets_survives() {
        // Parentheses without a sound word are the user's own punctuation.
        assert_eq!(
            strip_non_speech("Budget (see appendix) is final."),
            "Budget (see appendix) is final."
        );
        // Ordinary words that also appear in captions do not make prose a caption.
        for keep in [
            "The agenda (talking points) is attached.",
            "Use the (background) layer.",
            "We discussed (foreign policy) today.",
            "We met (after the music festival last summer in town) again.",
        ] {
            assert_eq!(strip_non_speech(keep), keep);
        }
        // Digits/symbols mean it is content, not a caption.
        assert_eq!(strip_non_speech("Use items[0] here."), "Use items[0] here.");
        assert_eq!(strip_non_speech("[TODO: fix] later"), "[TODO: fix] later");
        // Empty pairs are code/markdown, not captions.
        assert_eq!(strip_non_speech("Call init() first."), "Call init() first.");
        assert_eq!(strip_non_speech("use foo[] here"), "use foo[] here");
        assert_eq!(strip_non_speech("**Note** this"), "**Note** this");
        // Lone markers stay.
        assert_eq!(strip_non_speech("a * b = c"), "a * b = c");
        assert_eq!(strip_non_speech("Plain dictation."), "Plain dictation.");
    }

    #[test]
    fn uncaptioned_text_is_untouched() {
        // No caption removed → identical to the old trim-only behaviour.
        assert_eq!(strip_non_speech(".5 milligrams twice a day"), ".5 milligrams twice a day");
        assert_eq!(strip_non_speech("...so anyway, send it"), "...so anyway, send it");
        assert_eq!(strip_non_speech("ratio 3 : 1"), "ratio 3 : 1");
        assert_eq!(strip_non_speech("line one\nline two"), "line one\nline two");
        assert_eq!(strip_non_speech("  padded  "), "padded");
        // A caption mid-text tidies only the gap, and leading punctuation is kept.
        assert_eq!(
            strip_non_speech(".5 mg (coughs) daily"),
            ".5 mg daily"
        );
        // Typical whisper captions with modifiers.
        assert_eq!(strip_non_speech("(speaking in foreign language)"), "");
        assert_eq!(strip_non_speech("(crowd chattering) Hi."), "Hi.");
    }

    #[test]
    fn removing_a_caption_only_tidies_its_own_gap() {
        // Issue #95: a dropped caption used to re-space the WHOLE transcript.
        assert_eq!(strip_non_speech("line one\n[Music]\nline two"), "line one\nline two");
        assert_eq!(strip_non_speech("ratio 3 : 1 (coughs)"), "ratio 3 : 1");
        assert_eq!(strip_non_speech("a  b [Music] c"), "a  b c");
        assert_eq!(strip_non_speech("first.\n[applause] Second"), "first.\nSecond");
        assert_eq!(strip_non_speech("[Music], send it"), "send it");
    }

    #[test]
    fn beam_override_parses_and_caps() {
        assert_eq!(parse_beam(None), None);
        assert_eq!(parse_beam(Some("")), None);
        assert_eq!(parse_beam(Some("1")), None);
        assert_eq!(parse_beam(Some("0")), None);
        assert_eq!(parse_beam(Some("five")), None);
        assert_eq!(parse_beam(Some(" 5 ")), Some(5));
        assert_eq!(parse_beam(Some("64")), Some(8));
    }

    #[test]
    fn noisy_room_picks_beam_and_env_still_wins() {
        assert_eq!(refined_beam(None, false), None, "default stays greedy");
        assert_eq!(refined_beam(None, true), Some(NOISY_ROOM_BEAM));
        assert_eq!(refined_beam(Some("3"), true), Some(3), "explicit A/B width wins");
        assert_eq!(refined_beam(Some("3"), false), Some(3));
        assert_eq!(refined_beam(Some("junk"), true), Some(NOISY_ROOM_BEAM));
    }

    #[test]
    fn flag_override_is_strict() {
        assert!(parse_flag(Some("1")));
        assert!(parse_flag(Some("On")));
        assert!(parse_flag(Some("TRUE")));
        assert!(!parse_flag(Some("0")));
        assert!(!parse_flag(Some("yes please")));
        assert!(!parse_flag(None));
    }

    #[test]
    fn mock_returns_configured_text() {
        let mut m = MockAsr {
            refined: "hello world".into(),
        };
        assert_eq!(m.transcribe(&[0.1, 0.2]).unwrap().refined, "hello world");
    }

    #[test]
    fn mock_reports_empty_on_silence_window() {
        let mut m = MockAsr {
            refined: "x".into(),
        };
        assert!(matches!(m.transcribe(&[]), Err(AsrError::Empty)));
    }

    #[test]
    fn i16_conversion_is_normalized() {
        let f = pcm_i16_to_f32(&[0, i16::MAX, i16::MIN]);
        assert_eq!(f[0], 0.0);
        assert!((f[1] - 0.99997).abs() < 1e-4);
        assert_eq!(f[2], -1.0);
    }
}
