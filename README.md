# Eikon

Eikon is the app. This is where it is developed.

From Greek *eikon*, a likeness: a Windows or Linux game, shown on iPhone or iPad. Said “AY-kon.”

This is an unfinished prototype, not a working emulator. Nothing here runs a game on a device. FEX-Emu and Wine are the intended stack and are not built into an app yet.

The Sileo source is a separate repo: https://github.com/getBoolean/eikon-source
That repo is not a live source. The intended URL, later, is https://getboolean.github.io/eikon-source

Package id: `com.getboolean.eikon`.

There is no JIT bypass and no exploit. When JIT is available, it comes from Dopamine, from TrollStore, or, for AltStore installs, from an external tool.

## Requirements

- macOS with Xcode and its iOS SDK
- Homebrew, and the tools `make doctor` checks: `xcodegen`, `ldid-procursus`, `dpkg`, `uv`, `gh`, `zstd` and `xz`
- Python comes through uv; nothing uses the system Python

Devices need iOS 15.0 or later.

> **Untested on iOS 15 and 16.** The app is built for iOS 15, but it has only been tested on iOS and iPadOS 17 and later: no iOS 15 or 16 device is available, and current Xcode has no simulator older than iOS 17. Reports from iOS 15 or 16 devices are welcome.

## Building

```sh
make doctor      # check the tools
make bootstrap   # only if doctor reports something missing; installs with Homebrew
make all         # check, test, archive, package, verify
```

The main targets:

- `version`: write `build/generated/Version.xcconfig` from `VERSION` and git
- `check`: the credits and version checks
- `test`: the Swift tests and the script tests
- `archive`: build the app archive
- `package`: package it as `.ipa` and `.deb` in `dist/`
- `verify`: check the packaged artifacts
- `clean`: remove `build/` and `dist/`

`make all` builds one app binary and packages it two ways.

`make doctor` checks the toolchain. `make bootstrap` installs missing tools; run it only when you choose to.

`make project` generates `Eikon.xcodeproj` with XcodeGen. The project is never committed: edit `project.yml` and the files in `Config/`, then regenerate.

`make test-swift` runs the Swift tests, then installs and launches the app on the newest iPhone simulator. To pick a different simulator, set `EIKON_SIM_DESTINATION` to an `xcodebuild -destination` value.

Always generate the project with `make project`. It chooses which acknowledgements file the app bundles, so a bare `xcodegen generate` isn't supported.

### Adding a third-party library

Libraries come prebuilt from GitHub releases of forks; see `third_party/README.md`. In one commit:

1. Pin the release with `make pin-dep NAME=<name> TAG=<tag>`.
2. Add its entry to `third_party/credits.toml`, and copy its license files into `third_party/notices/<name>/`.
3. Add any missing `licenses/<SPDX-id>.txt`.
4. Run `uv run scripts/credits.py notices --write`.

`make check` must pass.

For debug runs on a device, create `Config/Local.xcconfig` (untracked) containing `DEVELOPMENT_TEAM = <your team id>`.

### Debug loop

When Eikon runs from Xcode on a device with the debugger attached, the kernel sets `CS_DEBUGGED` on the process. That exercises the real JIT probe without TrollStore.

The probe deliberately triggers signals and handles them itself, but lldb stops on them by default. To let the probe's handler deal with them, run this in lldb, or put it in a `.lldbinit`:

```
process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false
```

## Game drives

Games live in game drives. Import copies a game into one, so most users never arrange folders by hand. For files managed by hand (in the Files app, or on a USB drive added as a game drive), the layout is:

```
<game drive>/            Eikon's own folder ("On My iPad/Eikon"), or a folder you added
  <game folder>/         one folder per game, directly inside the drive
    Game.exe, data …     the game's files
  <game folder>/
    <wrapper>/           or the game inside one wrapper folder
      Game.exe, data …
```

A game nested any deeper, or still in an archive, is listed under "Not recognized". `make scan-collection` reads a folder laid out the same way.

## Install methods and artifacts

- **Dopamine rootless deb** (`com.getboolean.eikon.rootless`, `iphoneos-arm64`), installed at `/var/jb/Applications/Eikon.app`. For Dopamine; verified on iPadOS 17.0. Needs no Developer Mode. It replaces the old `com.getboolean.eikon` deb from 0.1.0.
- **`Eikon.ipa`** (`com.getboolean.eikon`) for **AltStore or TrollStore**:
  - With **AltStore**: it re-signs the ipa with the developer profile's entitlements, replacing the ones in the ipa, and may rewrite the bundle id.
  - With **TrollStore**: it re-signs the ipa, keeping its entitlements and adding `container-required`, which is how Eikon recognises the install. Enable "URL Scheme" in TrollStore's settings so Eikon can ask it for JIT.
  - On iOS 16 and later, **Developer Mode must be on**: the ipa carries `get-task-allow`.

The deb and the ipa use **different bundle ids** so a Dopamine install and a TrollStore-installed ipa can coexist. Both carry the same binary, signed with their own entitlements (`packaging/entitlements/`); `make verify` checks that.

## JIT

- Dopamine grants JIT automatically when its “Allow JIT in Apps” setting is on.
- On TrollStore 2.0.12 or later, with its "URL Scheme" setting on, the app asks TrollStore once to enable JIT, and TrollStore returns to the app.
- On AltStore, the app only detects JIT that an external tool has provided. On a jailbroken device that includes Dopamine's "Allow JIT in Apps", which gives JIT to every app, whatever installed it.
- On devices with Apple's Trusted Execution Monitor (iOS 26 and later, on chips that have it), the app reports JIT as not usable. The routes that don't need JIT still work.

The status screen shows whether JIT is usable, where it came from, and a reason when it isn't.

## Publishing

The Dopamine deb is served from the Sileo source `https://getboolean.github.io/eikon-source/` (with the trailing slash). Debs are GitHub Release assets on this repo; the `eikon-source` repository holds only the package index, generated by `scripts/repo/build_index.py`.

- **Who publishes.** CI is the canonical publisher: pushing a `v*` tag runs `release.yml` (section 12). `make publish` is the local fallback — run `make publish ARGS="--dry-run"` first to see the planned actions.
- **Release policy.** Release assets are never replaced. A fix means a new version; a re-uploaded asset would change its hashes and break Sileo's cached index.
- **Relative-mode fallback.** If Sileo can't follow the release-asset redirect, run the publisher with `--filename-mode relative`. The deb is then committed under `docs/debs/` while it stays under GitHub's 100 MB file limit.

## One-time setup (owner-run or owner-approved)

These are outward-facing and are **not** run automatically. Prepare each, then get owner approval (section 12).

1. **Deploy key** so CI can push to `eikon-source`:
   ```sh
   ssh-keygen -t ed25519 -N "" -f eikon-source-deploy
   gh repo deploy-key add eikon-source-deploy.pub --repo getBoolean/eikon-source --allow-write --title "eikon publish"
   # In getBoolean/eikon, create an Environment "eikon-source" with the owner as required reviewer, then:
   gh secret set EIKON_SOURCE_DEPLOY_KEY --repo getBoolean/eikon --env eikon-source < eikon-source-deploy
   rm -f eikon-source-deploy eikon-source-deploy.pub
   ```
2. **Enable Pages** after the first publish has populated `docs/`:
   ```sh
   gh api -X POST repos/getBoolean/eikon-source/pages -f 'source[branch]=main' -f 'source[path]=/docs'
   # If Pages already exists, use -X PUT.
   ```
3. **Repo description:**
   ```sh
   gh repo edit getBoolean/eikon-source --description "The Sileo source for Eikon (package index only)." --homepage https://getboolean.github.io/eikon-source/
   ```

## License

GPL-3.0-or-later; see `LICENSE`. Third-party notices will be in `THIRD_PARTY_NOTICES.md`.
