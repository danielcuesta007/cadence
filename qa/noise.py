"""Noise mixing for the §30 robustness bench (Step 15, background noise in loud rooms).

Pure, stdlib-only helpers: read/write 16 kHz mono 16-bit WAV, measure RMS, synthesize a
deterministic "room speaker" music bed, sum several voices into cafeteria babble, and mix
noise under speech at an exact signal-to-noise ratio. qa/noise-fixtures.sh drives these to
build qa/fixtures/wer-noise/<condition>/; qa/test_noise.py pins the maths.

Synthetic noise is a proxy: it ranks settings against each other and catches regressions,
it does NOT stand in for a real cafeteria (no room reverb, no mic colouring). Claims about
real-world filtering need the consented live A/B described in docs/STATUS.md.
"""

import array
import math
import random
import wave

RATE = 16_000


def read_wav(path):
    """16-bit mono PCM samples as floats in [-1, 1]. Rejects anything else loudly."""
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"{path}: need 16-bit mono, got {w.getnchannels()}ch/{w.getsampwidth() * 8}bit")
        if w.getframerate() != RATE:
            raise ValueError(f"{path}: need {RATE} Hz, got {w.getframerate()}")
        raw = array.array("h", w.readframes(w.getnframes()))
    return [s / 32768.0 for s in raw]


def write_wav(path, samples):
    """Write floats as 16-bit mono PCM, clipping to the representable range."""
    out = array.array("h", (max(-32768, min(32767, int(round(s * 32767)))) for s in samples))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(out.tobytes())


def rms(samples):
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))


def fit(noise, n, offset=0):
    """Noise looped/trimmed to exactly n samples, starting at offset (so fixtures differ)."""
    if not noise:
        raise ValueError("empty noise source")
    m = len(noise)
    return [noise[(offset + i) % m] for i in range(n)]


def mix_at_snr(speech, noise, snr_db, offset=0):
    """speech + noise scaled so 20*log10(rms(speech)/rms(noise)) == snr_db.

    Returns (mixed, peak). If the mix would clip, BOTH parts are scaled down together, which
    keeps the SNR exact; the caller can report peak to show it happened.
    """
    n = len(speech)
    bed = fit(noise, n, offset)
    s_rms, n_rms = rms(speech), rms(bed)
    if s_rms == 0 or n_rms == 0:
        raise ValueError("speech and noise must both be non-silent")
    gain = s_rms / (n_rms * 10 ** (snr_db / 20))
    mixed = [a + b * gain for a, b in zip(speech, bed)]
    peak = max(abs(x) for x in mixed)
    if peak > 0.99:
        k = 0.99 / peak
        mixed = [x * k for x in mixed]
    return mixed, peak


def babble(sources, offsets=None):
    """Sum several voice recordings into one bed (each looped to the longest), RMS-normalised
    so every talker contributes about equally, like a table of people talking at once."""
    if not sources:
        raise ValueError("babble needs at least one voice")
    n = max(len(s) for s in sources)
    offsets = offsets or [0] * len(sources)
    bed = [0.0] * n
    for src, off in zip(sources, offsets):
        level = rms(src) or 1.0
        for i, v in enumerate(fit(src, n, off)):
            bed[i] += v / level
    peak = max(abs(x) for x in bed) or 1.0
    return [x * 0.5 / peak for x in bed]


def music(seconds, seed=7):
    """Deterministic speaker-music stand-in: a I–V–vi–IV chord loop with a bass line and a
    soft hi-hat, so it has the harmonic, rhythmic texture whisper tends to hallucinate on."""
    rnd = random.Random(seed)
    n = int(seconds * RATE)
    # A major-ish progression (root, third, fifth in Hz), half a second per beat, 4 beats a chord.
    chords = [(220.0, 277.18, 329.63), (164.81, 207.65, 246.94),
              (185.0, 220.0, 277.18), (146.83, 185.0, 220.0)]
    beat = RATE // 2
    out = []
    for i in range(n):
        chord = chords[(i // (beat * 4)) % len(chords)]
        t = i / RATE
        pos = (i % beat) / beat
        env = math.exp(-3.0 * pos)
        v = sum(math.sin(2 * math.pi * f * t) for f in chord) * 0.18 * (0.4 + 0.6 * env)
        v += math.sin(2 * math.pi * chord[0] / 2 * t) * 0.25 * env
        if (i % (beat // 2)) < RATE // 100:  # 10 ms hat on every eighth note
            v += (rnd.random() * 2 - 1) * 0.15
        out.append(v)
    peak = max(abs(x) for x in out) or 1.0
    return [x * 0.5 / peak for x in out]
