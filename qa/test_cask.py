"""The Homebrew cask must install without admin rights and without a Gatekeeper block.

Pinned because both regressions are silent: `brew install` either fails on a non-admin
account (Permission denied into /Applications) or succeeds and leaves an app macOS refuses
to open. Checked against the file's text, so no Homebrew is needed to run it.
"""
import pathlib
import re
import unittest

CASK = (pathlib.Path(__file__).resolve().parent.parent / 'Casks' / 'cadence.rb').read_text()


class CaskTest(unittest.TestCase):
    def test_falls_back_to_user_applications(self):
        self.assertIn('File.writable?("/Applications")', CASK)
        self.assertIn('File.expand_path("~/Applications")', CASK)
        self.assertRegex(CASK, r'app "Cadence.app", target: "#\{apps_dir\}/Cadence.app"')

    def test_clears_quarantine_after_checksum(self):
        self.assertRegex(CASK, r'(?s)postflight do.*"/usr/bin/xattr".*"-dr", "com.apple.quarantine", "#\{apps_dir\}/Cadence.app"')
        self.assertRegex(CASK, r'(?m)^  sha256 "[0-9a-f]{64}"$')  # the clear is only safe after a verified download

    def test_no_deprecated_macos_string(self):
        # Homebrew 7 warns on the string form ">= :sonoma" on every command.
        self.assertIsNone(re.search(r'depends_on macos: "', CASK))
        self.assertIn('depends_on macos: :sonoma', CASK)

    def test_release_script_can_still_stamp_it(self):
        # qa/make-dmg.sh rewrites these two lines with sed; they must keep this exact shape.
        self.assertRegex(CASK, r'(?m)^  version "[^"]+"$')
        self.assertRegex(CASK, r'(?m)^  sha256 "[^"]+"$')


if __name__ == '__main__':
    unittest.main()
