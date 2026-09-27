# Device reports and the verification runbook

A device report is one JSON file describing what a launch of Eikon detected: the
build, how it was installed, the JIT status, basic device facts and available
memory. The app builds it on the status screen (**Copy report** / **Share
report**), and `scripts/file_device_report.py` validates and files it here.

**Privacy.** A report never contains the device name, UDID, serial number, or any
program or game title. Paths are redacted to their structure. Notes added before
filing must follow the same rule: no program titles, nothing device-identifying.

The artifacts used below come from the **GitHub Release**, not local builds, so the
reports describe what users actually install. `<v>` is the released version.

## iPad Pro 12.9" 6th gen (M2), iPadOS 17.0

### TrollStore
1. With Developer Mode on, install `Eikon-<v>.tipa` and launch it.
2. Expect TrollStore to open and return, then the status screen to show **usable**, source `trollStore`.
3. File the report.
4. Disable TrollStore's URL scheme, then relaunch after the cooldown. Expect **not usable**, reason `trollStoreTimedOut`. Re-enable the scheme, press **Retry JIT**, and expect usable again.
5. Turn Developer Mode off and try to launch. Record in the report notes what happens: a TrollStore install warning, a launch refusal, or a launch without JIT.

### Dopamine 3 (if it supports this device)
1. Uninstall the `.tipa` first; both use the same bundle id.
2. Add `https://getboolean.github.io/eikon-source/` in Sileo, install Eikon, and launch.
3. Expect **usable** at first paint, source `dopamine`.
4. File the report. Its notes should also answer:
   - where the data and home directories ended up
   - whether Sileo followed the GitHub release-asset redirect
   - whether `uicache` in `postinst` worked as root, or needs to run as `mobile`
5. Turn "Allow JIT in Apps" off in Dopamine and relaunch. Expect **not usable**, reason `dopamineJITOff`. File this report too.

If Dopamine 3 can't run on this device, write that down; the deb is then desktop-verified only.

**Debug loop (optional).** An Xcode-debugged run on the device exercises the real functional probe; follow the debug-loop note in the top-level `README.md`.

## iPhone 13 mini (A15), iOS 27.0

### AltStore
1. Install `Eikon-<v>.ipa` with AltStore.
2. Record any capability errors for `increased-memory-limit` or `extended-virtual-addressing`, and whether the install succeeds.
3. Launch. Expect **not usable**, reason `txmEnforced`, with or without an external JIT enabler — this device has Apple's Trusted Execution Monitor.
4. File the report.

## Filing

1. Export the report from the app (**Share report**, or **Copy report** and paste into a file).
2. Run `uv run scripts/file_device_report.py <path>` (or `-` for stdin). It validates the report, rejects unknown schema versions, and writes `device-reports/<date>-<model>-<method>-<hash>.json`. Refiling an identical report is a no-op.
3. Commit the filed reports. Pushing them is outward-facing, so ask the owner first.

## Expected results

| Device | Install | Expected JIT | Source or reason |
|---|---|---|---|
| iPad M2, 17.0 | TrollStore | usable | `trollStore` |
| iPad M2, 17.0 | TrollStore, scheme disabled | not usable | `trollStoreTimedOut` |
| iPad M2, 17.0 | Dopamine 3 | usable | `dopamine` |
| iPad M2, 17.0 | Dopamine 3, JIT off | not usable | `dopamineJITOff` |
| iPhone A15, 27.0 | AltStore | not usable | `txmEnforced` |

## Follow-ups from what the reports show

Each of these is a change that goes through normal review, and any new release is a new version:

- **Sileo didn't follow the redirect:** publish with `build_index.py`'s `--filename-mode relative`, committing the deb under `docs/debs/` while it's under 100 MB.
- **AltStore rejected a capability:** drop that key from `packaging/entitlements/ipa.plist` and note it in `packaging/entitlements/README.md`.
- **`uicache` needs `mobile`:** adjust `packaging/deb/postinst` and `prerm`.
- **Dopamine 3 unsupported on the iPad:** record the deb as desktop-verified only.
- **The TXM table was wrong for a CPU family:** correct the CPU-family table in `Packages/EikonKit/Sources/EikonKit/TXMTable.swift`.
