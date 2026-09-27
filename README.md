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
- `package`: package it as `.ipa`, `.tipa` and `.deb` in `dist/`
- `verify`: check the packaged artifacts
- `clean`: remove `build/` and `dist/`

`make all` builds one app binary and packages it three ways.

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

## Install methods and artifacts

- **Dopamine rootless deb** (`com.getboolean.eikon`, `iphoneos-arm64`), installed at `/var/jb/Applications/Eikon.app`. Supported on Dopamine 2, for iOS 15.0–16.6.1.
- **`Eikon.tipa`** for TrollStore, up to iOS 17.0. On iOS 16 and later, **Developer Mode must be on**: the `.tipa` carries `get-task-allow`, which TrollStore's enable-JIT feature needs.
- **`Eikon.ipa`** for AltStore, on current iOS. AltStore re-signs it with the developer profile's entitlements, replacing the ones in the ipa.

The deb needs no Developer Mode. Each artifact carries the same binary, signed with its own entitlements (`packaging/entitlements/`); `make verify` checks that.

## JIT

- Dopamine grants JIT automatically when its “Allow JIT in Apps” setting is on.
- On TrollStore 2.0.12 or later, the app asks TrollStore once to enable JIT, and TrollStore returns to the app.
- On AltStore, the app only detects JIT that an external tool has provided.
- On devices with Apple's Trusted Execution Monitor (iOS 26 and later, on chips that have it), the app reports JIT as not usable. The routes that don't need JIT still work.

The status screen shows whether JIT is usable, where it came from, and a reason when it isn't.

## License

GPL-3.0-or-later; see `LICENSE`. Third-party notices will be in `THIRD_PARTY_NOTICES.md`.
