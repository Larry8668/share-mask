# Releasing

`main` is protected: changes land through pull requests (no approvals required, applies to admins
too; force-pushes and deletion are blocked). Do the version bump below on a branch and merge a PR.

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. `make release` → `build/sharemask-<version>.zip` and its sha256.
3. `gh release create v<version> build/sharemask-<version>.zip --title "sharemask <version>" --notes "..."`
   (the repo must be public for Homebrew to download the asset without auth).
4. Update `version` and `sha256` in `packaging/sharemask.rb`, copy it to the tap repo
   `Larry8668/homebrew-sharemask` as `Casks/sharemask.rb`, commit, push.
5. Users: `brew tap Larry8668/sharemask && brew trust Larry8668/sharemask && brew install --cask sharemask`;
   upgrades via `brew upgrade --cask sharemask`. The cask's postflight strips the quarantine
   attribute (Homebrew 7 removed `--no-quarantine`).

The signing certificate must stay the same across releases (it is what keeps the Screen
Recording grant); `make identity` creates it once per machine, so releases should be built on the
same machine (or the exported `sharemask-dev` p12 imported elsewhere).
