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
  version "0.1.10"
  sha256 "513d3739902943af2e38adc1e42e399f5756ac6f4003cd225f06582526806e78"

  url "https://github.com/Larry8668/share-mask/releases/download/v#{version}/sharemask-#{version}.zip"
  name "sharemask"
  desc "Share your screen with chosen app regions pixellated only on the shared feed"
  homepage "https://github.com/Larry8668/share-mask"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "sharemask.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/sharemask.app"], sudo: false
    saved = File.expand_path("~/Library/Caches/sharemask-agent.plist.upgrade")
    agent = File.expand_path("~/Library/LaunchAgents/dev.sharemask.keepalive.plist")
    if File.exist?(saved)
      FileUtils.mv(saved, agent)
      system_command "/bin/launchctl", args: ["bootstrap", "gui/#{Process.uid}", agent], must_succeed: false
    end
  end

  caveats <<~EOS
    sharemask is not notarised; the quarantine flag was removed so it opens normally. If macOS
    still refuses, right-click the app and choose Open once. On first launch grant Screen Recording
    in System Settings → Privacy & Security → Screen & System Audio Recording.
  EOS

  # App lock's optional keep-alive agent. On uninstall it's unloaded and set aside (no sudo); on an
  # upgrade the new version's postflight puts it back and relaunches sharemask, so App lock keeps
  # running across upgrades. A plain uninstall leaves only the set-aside copy in ~/Library/Caches.
  uninstall script: {
    executable: "/bin/sh",
    args:       ["-c", 'launchctl bootout "gui/$(id -u)/dev.sharemask.keepalive" 2>/dev/null; ' \
                       'P="$HOME/Library/LaunchAgents/dev.sharemask.keepalive.plist"; ' \
                       '[ -f "$P" ] && mv -f "$P" "$HOME/Library/Caches/sharemask-agent.plist.upgrade"; true'],
    sudo:       false,
  }

  zap trash: [
    "~/Library/LaunchAgents/dev.sharemask.keepalive.plist",
    "~/Library/Caches/sharemask-agent.plist.upgrade",
    "~/.config/sharemask",
    "~/Library/Logs/sharemask",
  ]
end
