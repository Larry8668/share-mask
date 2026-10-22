# Homebrew cask for sharemask. Lives in the tap repo github.com/Larry8668/homebrew-sharemask
# as Casks/sharemask.rb; this copy is the source of truth, synced on each release.
#
#   brew tap Larry8668/sharemask
#   brew install --cask --no-quarantine sharemask
#
# --no-quarantine matters: the app is signed with a self-signed certificate (stable, so the Screen
# Recording grant survives updates) but is not notarised, so Gatekeeper would otherwise refuse it.
cask "sharemask" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_make_release"

  url "https://github.com/Larry8668/share-mask/releases/download/v#{version}/sharemask-#{version}.zip"
  name "sharemask"
  desc "Share your screen with chosen app regions pixellated only on the shared feed"
  homepage "https://github.com/Larry8668/share-mask"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "sharemask.app"

  caveats <<~EOS
    sharemask is not notarised. If macOS refuses to open it, install with --no-quarantine or
    right-click the app and choose Open once. On first launch grant Screen Recording in
    System Settings → Privacy & Security → Screen & System Audio Recording.
  EOS

  zap trash: [
    "~/.config/sharemask",
    "~/Library/Logs/sharemask",
  ]
end
