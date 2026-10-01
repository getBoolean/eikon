# Usage Guide: split 02 (app shell)

## Quick start

```
make doctor              # check the toolchain
make test                # EikonCore on the Mac, EikonCore + EikonKit on the simulator, script tests
make all                 # check, test, archive, package, verify
make scan-collection     # title-free scan of /Volumes/Games (skipped when not mounted)
```

Install `dist/Eikon-<v>.ipa` (AltStore, TrollStore) or the rootless deb (Dopamine). The app opens on **Library**.

## In the app

- **Library.** Lists games found in game drives.
  - Pull down to rescan.
  - **+** imports a game. You pick a folder and a drive, and the files are copied; the original folder isn't changed.
  - Tap a game for its detail screen:
    - name, engine and locations
    - **Launch**, disabled with a reason until a route is built (none are in split 02)
    - the route list, which also sets the override
    - recent crashes, with **Report on GitHub**
    - identity tools: merge, split, Verify files, retry
    - **Remove**
- **Game drives.** The built-in drive is "On My iPad/Eikon" (iPhone: "On My iPhone/Eikon"). **Add game drive…** adds a folder on the device or a USB drive. Swipe or long-press a drive to find its folder again, or to remove the drive (its files stay).
  - Each game sits directly inside a drive, or inside one wrapper folder there. See README → Game drives.
- **This device.**
  - JIT, routes and device checks.
  - **Copy report** / **Share report**, which include gates.
  - **Developer**, collapsed: run a test session, simulate a crash (the app quits about 5 s in, and the next launch shows the crash banner), the settings replica ID, and the raw gate store.
- **Credits.** Eikon first, then third-party components, each with its full license text.

## Scanner

```
swift run --package-path Packages/EikonCore -c release eikon-scan [--per-folder] [--hash] <drive folder>
```

The scanner prints counts by engine, architecture, plugins, exclusions and identity statistics. It never prints titles or folder names. With `--per-folder`, it adds one line per folder giving its engine and a short fingerprint.

## Credits pipeline

```
uv run scripts/credits.py app-json build/generated/Acknowledgements.json   # run by `make generated`
```

The output is a JSON array. Eikon's own entry comes first (`isApp: true`), followed by one entry per `[[component]]` in `third_party/credits.toml` (`isApp: false`).

## Key interfaces

- **`LibraryController`** (EikonKit):
  - drives: `addDrive`, `relinkDrive`, `removeDrive`, `reevaluateDriveStates`
  - library: `rescan`, `importGame(from:to:naming:)` with `cancelImport`
  - identity: `merge`, `split(location:)`, `dismissSuggestion`, `retryFingerprint`
  - removal: `forget(location:)` (missing locations only), `remove(game:deleteLocations:deleteData:)`
  - launch: `launchLocation(for:)`
- **`CrashReportController`:** `banner`, `history(for:links:)`, `tryAlternative`, `report`, `dismiss`.
- **`SessionPresenter`** (App): `launch(_:game:route:runtime:)` for games, `launchTest(_:runtime:)` for the developer test pattern. `isSessionActive` is published.
- **`Acknowledgements`** (EikonKit): `load(bundle:)` returns `Result<Acknowledgements, AcknowledgementsError>`, and `decode(_:)` parses data.
