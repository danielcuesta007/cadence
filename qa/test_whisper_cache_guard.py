"""qa/whisper-cache-guard.sh drops whisper.cpp caches built for the wrong macOS."""

import pathlib
import subprocess
import tempfile
import unittest

GUARD = pathlib.Path(__file__).resolve().parent / "whisper-cache-guard.sh"


def make_cache(root: pathlib.Path, name: str, target):
    build = root / "release" / "build" / name
    out = build / "out" / "build"
    out.mkdir(parents=True)
    lines = ["CMAKE_BUILD_TYPE:STRING=Release"]
    if target is not None:
        lines.append(f"CMAKE_OSX_DEPLOYMENT_TARGET:STRING={target}")
    (out / "CMakeCache.txt").write_text("\n".join(lines) + "\n")
    return build


class WhisperCacheGuardTest(unittest.TestCase):
    def run_guard(self, root: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(GUARD), str(root), "14.0"], capture_output=True, text=True, check=True
        )

    def test_drops_caches_for_another_macos_and_keeps_matching_ones(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            unset = make_cache(root, "whisper-rs-sys-aaa", "")
            newer = make_cache(root, "whisper-rs-sys-bbb", "26.5")
            good = make_cache(root, "whisper-rs-sys-ccc", "14.0")
            other = make_cache(root, "openssl-sys-ddd", "")
            result = self.run_guard(root)
            self.assertFalse(unset.exists(), "empty target means the build Mac's OS")
            self.assertFalse(newer.exists())
            self.assertTrue(good.exists(), "a matching cache must not cost a rebuild")
            self.assertTrue(other.exists(), "only whisper caches are touched")
            self.assertIn("rebuilding", result.stderr)

    def test_no_target_dir_is_fine(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_guard(pathlib.Path(tmp) / "missing")
            self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
