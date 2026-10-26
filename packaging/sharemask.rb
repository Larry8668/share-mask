# Homebrew cask for sharemask. Lives in the tap repo github.com/Larry8668/homebrew-sharemask
# as Casks/sharemask.rb; this copy is the source of truth, synced on each release.
#
#   brew tap Larry8668/sharemask
#   brew trust Larry8668/sharemask        # Homebrew 7+ requires trusting third-party taps
#   brew install --cask sharemask
#
# The app is signed with a self-signed certificate (stable, so the Screen Recording grant survives
# updates) but is not notarised, so Gatekeeper would refuse the quarantined download. The
# postflight below removes the quarantine attribute (Homebrew 7 dropped --no-quarantine).
cask "sharemask" do
  version "0.1.6"
  sha256 "055172e6cab65fb57ade0071796f1fb4fb33aaae577a7ce5b46656f256a41032"

  url "https://github.com/Larry8668/share-mask/releases/download/v#{version}/sharemask-#{version}.zip"
  name "sharemask"
  desc "Share your screen with chosen app regions pixellated only on the shared feed"
  homepage "https://github.com/Larry8668/share-mask"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "sharemask.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/sharemask.app"], sudo: false
  end

  caveats <<~EOS
    sharemask is not notarised; the quarantine flag was removed so it opens normally. If macOS
    still refuses, right-click the app and choose Open once. On first launch grant Screen Recording
    in System Settings → Privacy & Security → Screen & System Audio Recording.
  EOS

  zap trash: [
    "~/.config/sharemask",
    "~/Library/Logs/sharemask",
  ]
end
