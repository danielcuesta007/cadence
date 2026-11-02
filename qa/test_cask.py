"""The Homebrew cask must install without admin rights and without a Gatekeeper block.

Pinned because both regressions are silent: `brew install` either fails on a non-admin
account (Permission denied into /Applications) or succeeds and leaves an app macOS refuses
to open. Checked against the file's text, so no Homebrew is needed to run it; the real
install was verified with Homebrew 7 (see PR #77).
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASK = (ROOT / 'Casks' / 'cadence.rb').read_text()


class CaskTest(unittest.TestCase):
    def test_relative_target_so_appdir_is_honoured(self):
        # An absolute target would ignore --appdir and break upgrade/uninstall tracking.
        self.assertRegex(CASK, r'(?m)^  app "Cadence\.app"$')

    def test_clears_quarantine_on_the_installed_app(self):
        clear = r'\["-dr", "com\.apple\.quarantine", "#\{appdir\}/Cadence\.app"\]'
        self.assertRegex(CASK, r'(?m)^  unquarantine = ' + clear + '$')
        # Homebrew 7 step syntax, with the old block kept for older Homebrew.
        self.assertRegex(CASK, r'(?s)postflight_steps do\s+run "/usr/bin/xattr", args: unquarantine')
        self.assertRegex(CASK, r'(?s)postflight do\s+system_command "/usr/bin/xattr", args: unquarantine')

    def test_checksum_is_pinned(self):
        # Clearing quarantine is only safe because Homebrew verifies this first.
        self.assertRegex(CASK, r'(?m)^  sha256 "[0-9a-f]{64}"$')
        self.assertNotIn(':no_check', CASK)

    def test_no_deprecated_macos_string(self):
        self.assertIsNone(re.search(r'depends_on macos: "', CASK))
        self.assertIn('depends_on macos: :sonoma', CASK)

    def test_release_script_can_still_stamp_version(self):
        self.assertRegex(CASK, r'(?m)^  version "[^"]+"$')

    def test_documented_command_needs_no_admin(self):
        cmd = 'brew install --cask --appdir=~/Applications cadence'
        for rel in ('README.md', 'site/download.html', 'Casks/cadence.rb'):
            text = (ROOT / rel).read_text()
            self.assertIn(cmd, text, rel)
            self.assertNotIn('brew install --cask cadence', text, rel)


if __name__ == '__main__':
    unittest.main()
