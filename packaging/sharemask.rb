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
  version "0.2.2"
  sha256 "a192ec42fa3ebe3ffca254a368b30a561819bd6e1a9aa16c2108ea8da05a6bd9"

  url "https://github.com/Larry8668/share-mask/releases/download/v#{version}/sharemask-#{version}.zip"
  name "sharemask"
  desc "Share your screen with chosen app regions pixellated only on the shared feed"
  homepage "https://github.com/Larry8668/share-mask"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "sharemask.app"

  # Homebrew 7 install steps (replaces the deprecated `postflight` block):
  #  - strip quarantine (the app is signed with a self-signed certificate, not notarised);
  #  - put App lock's keep-alive agent back if the uninstall step set it aside. It can't be loaded
  #    from here: Homebrew 7 runs install steps in a sandbox that can't reach launchd ("Bootstrap
  #    failed: 5"). It loads at the next login or when sharemask is opened; sharemask's own
  #    "Update now" reloads it right away (its script runs in Terminal).
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/sharemask.app"], must_succeed: false,
        writable_paths: ["sharemask.app"], writable_base: :appdir
    if_path_exists "Library/Caches/sharemask-agent.plist.upgrade", base: :home do
      move "Library/Caches/sharemask-agent.plist.upgrade", "Library/LaunchAgents/dev.sharemask.keepalive.plist",
           source_base: :home, target_base: :home
    end
  end

  caveats <<~EOS
    Open sharemask, then look for the crossed eye (⊘) in your menu bar; a welcome window walks you
    through the two permissions. After `brew upgrade`, open it once more (or use Update now in its menu).
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
