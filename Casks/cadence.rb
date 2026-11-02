# Homebrew cask for Cadence.
#   brew tap danielcuesta007/cadence https://github.com/danielcuesta007/cadence
#   brew install --cask --appdir=~/Applications cadence   (no admin rights needed)
# qa/make-dmg.sh fills in version and sha256 for each release.
cask "cadence" do
  version "0.1.5"
  sha256 "bfefc929442146a405dbe9d43ae862068cd51457a91ba714a742581578501d70"

  url "https://github.com/danielcuesta007/cadence/releases/download/v#{version}/Cadence.dmg"
  name "Cadence"
  desc "On-device, offline push-to-talk dictation"
  homepage "https://cadence-dictation.pages.dev"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # A plain relative target, so Homebrew's --appdir is honoured and remembered for
  # upgrade/uninstall. The documented command passes --appdir=~/Applications, which needs
  # no admin rights (Homebrew's default, /Applications, needs an admin on most Macs).
  app "Cadence.app"

  # Cadence isn't notarized (that costs $99 a year, and Cadence is free). Homebrew marks
  # what it downloads as "from the internet", which would make macOS block the first open.
  # The download was already checked against the sha256 above, so clear that mark on this
  # one app, exactly as the one-line installer does.
  # Homebrew 7 runs this as a sandboxed install step; older Homebrew only knows the
  # postflight block, so fall back to it rather than fail to load.
  unquarantine = ["-dr", "com.apple.quarantine", "#{appdir}/Cadence.app"]
  if respond_to?(:postflight_steps)
    postflight_steps do
      run "/usr/bin/xattr", args: unquarantine, must_succeed: false
    end
  else
    postflight do
      system_command "/usr/bin/xattr", args: unquarantine, must_succeed: false
    end
  end

  caveats <<~EOS
    Cadence is in #{appdir}. Open it once; it lives in the menu bar and asks for
    Microphone and Accessibility the first time.
    If macOS still says it can't be opened: System Settings > Privacy & Security >
    Open Anyway, or run: xattr -dr com.apple.quarantine "#{appdir}/Cadence.app"
    Your dictation history lives in ~/.cadence; uninstalling the app leaves it in place.
  EOS
end
