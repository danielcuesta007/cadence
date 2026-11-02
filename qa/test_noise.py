"""Unit tests for qa/noise.py (python3 -B -m unittest qa.test_noise)."""

import math
import os
import tempfile
import unittest

from qa import noise


def tone(freq, seconds, amp=0.3):
    return [amp * math.sin(2 * math.pi * freq * i / noise.RATE) for i in range(int(seconds * noise.RATE))]


def snr_db(clean, mixed):
    resid = [m - c for m, c in zip(mixed, clean)]
    return 20 * math.log10(noise.rms(clean) / noise.rms(resid))


class MixAtSnr(unittest.TestCase):
    def test_hits_requested_snr(self):
        speech, bed = tone(440, 1.0), tone(97, 0.3, amp=0.8)
        for target in (10, 5, 0):
            mixed, _ = noise.mix_at_snr(speech, bed, target)
            self.assertAlmostEqual(snr_db(speech, mixed), target, places=2)

    def test_clip_guard_keeps_snr_and_peak(self):
        speech, bed = tone(440, 0.5, amp=0.95), tone(97, 0.5, amp=0.9)
        mixed, peak = noise.mix_at_snr(speech, bed, 0)
        self.assertGreater(peak, 0.99)  # it would have clipped
        self.assertLessEqual(max(abs(x) for x in mixed), 0.99 + 1e-9)
        # scaled together: the clean part shrank by the same factor, so SNR still holds
        k = max(abs(x) for x in mixed) / peak
        self.assertAlmostEqual(snr_db([s * k for s in speech], mixed), 0, places=2)

    def test_output_length_matches_speech(self):
        mixed, _ = noise.mix_at_snr(tone(440, 0.7), tone(97, 0.1), 5)
        self.assertEqual(len(mixed), int(0.7 * noise.RATE))

    def test_silence_rejected(self):
        with self.assertRaises(ValueError):
            noise.mix_at_snr([0.0] * 100, tone(97, 0.1), 5)


class Sources(unittest.TestCase):
    def test_fit_loops_with_offset(self):
        self.assertEqual(noise.fit([1, 2, 3], 5, offset=1), [2, 3, 1, 2, 3])

    def test_music_deterministic_and_bounded(self):
        a, b = noise.music(1.0), noise.music(1.0)
        self.assertEqual(a, b)
        self.assertLessEqual(max(abs(x) for x in a), 0.5 + 1e-9)
        self.assertGreater(noise.rms(a), 0.05)

    def test_babble_balances_talkers(self):
        loud, quiet = tone(300, 0.5, amp=0.9), tone(500, 0.5, amp=0.01)
        bed = noise.babble([loud, quiet])
        # the quiet talker is normalised up, not drowned: its component is present
        quiet_part = noise.babble([quiet])
        self.assertGreater(noise.rms(quiet_part), 0.1)
        self.assertLessEqual(max(abs(x) for x in bed), 0.5 + 1e-9)


class WavRoundTrip(unittest.TestCase):
    def test_round_trip(self):
        s = tone(440, 0.2)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.wav")
            noise.write_wav(p, s)
            back = noise.read_wav(p)
        self.assertEqual(len(back), len(s))
        self.assertLess(max(abs(a - b) for a, b in zip(s, back)), 1e-4)


if __name__ == "__main__":
    unittest.main()
