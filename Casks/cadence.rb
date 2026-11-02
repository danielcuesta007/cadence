# Homebrew cask for Cadence.
#   brew tap danieljcuesta007/cadence https://github.com/danieljcuesta007/cadence
#   brew install --cask cadence
# qa/make-dmg.sh fills in version and sha256 for each release.
cask "cadence" do
  version "0.1.3"
  sha256 "63e315ea93b98916ac648cd7b1d70ad8cfe885bdf94ba031f3dea38cf57c31c1"

  url "https://github.com/danieljcuesta007/cadence/releases/download/v#{version}/Cadence.dmg"
  name "Cadence"
  desc "On-device, offline push-to-talk dictation"
  homepage "https://cadence-dictation.pages.dev"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # Works without admin rights: /Applications when this account can write to it,
  # --appdir always wins.
  apps_dir = File.writable?("/Applications") ? "/Applications" : File.expand_path("~/Applications")
  app "Cadence.app", target: "#{apps_dir}/Cadence.app"

  # Cadence isn't notarized (that costs $99 a year, and Cadence is free). Homebrew marks
  # what it downloads as "from the internet", which would make macOS block the first open.
  # The download was already checked against the sha256 above, so clear that mark on this
  # one app, exactly as the one-line installer does.
  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{apps_dir}/Cadence.app"],
                   must_succeed: false
  end

  caveats <<~EOS
    Cadence is in #{apps_dir}. Open it once; it lives in the menu bar and asks for
    Microphone and Accessibility the first time.
    Your dictation history lives in ~/.cadence; uninstalling the app leaves it in place.
  EOS
end
