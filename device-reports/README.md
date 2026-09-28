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

**One method at a time.** The Dopamine deb (`com.getboolean.eikon.rootless`) and the ipa (`com.getboolean.eikon`) have different bundle ids and can coexist. A TrollStore-installed ipa and an AltStore-installed ipa share the id `com.getboolean.eikon`, so installing one shadows the other — uninstall (and reboot or `uicache`) before switching between them.

## iPad Pro 12.9" 6th gen (M2), iPadOS 17.0

### TrollStore (the `.ipa`, not a separate tipa)
1. With Developer Mode on, install `Eikon-<v>.ipa` **with TrollStore** and launch it.
2. Record the **Detected method** and **Bundle ID** on the status screen. We expect `trollStore`; the report confirms what markers TrollStore leaves for an ipa install.
3. Use TrollStore's **"Open with JIT"** (or the enable-JIT flow) and relaunch. Expect **usable**. File the report.
4. Launch normally (without Open with JIT). If it's not usable, note the reason; press **Retry JIT** and see whether TrollStore's enable-JIT URL grants it.
5. Turn Developer Mode off and try to launch. Record what happens: a TrollStore warning, a launch refusal, or a launch without JIT.

### Dopamine 3 (if it supports this device)
1. The deb has its own id, so it won't collide with a TrollStore ipa — but uninstall an AltStore ipa first if one is present.
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
1. Install `Eikon-<v>.ipa` with AltStore. **This is the key check for 0.2.0:** the ipa now embeds two private entitlements it didn't in 0.1.0 (`com.apple.private.security.no-sandbox`, `com.apple.private.memorystatus`). AltStore is expected to drop them when it re-signs, but if it validates and **rejects** them the install fails. If it does, drop those two keys from `packaging/entitlements/ipa.plist` and cut a new version.
2. Record any capability errors for `increased-memory-limit` or `extended-virtual-addressing`, and whether the install succeeds.
3. Launch. Expect **not usable**, reason `txmEnforced`, with or without an external JIT enabler — this device has Apple's Trusted Execution Monitor.
4. File the report.

## LiveContainer (exploratory — either device)

Eikon has no explicit LiveContainer support yet. Running it as a guest inside
LiveContainer is expected to detect as `sideloaded` or `unknown`, and — if
LiveContainer (via SideStore/JITStreamer, or a TrollStore-installed
LiveContainer) has granted JIT — to report JIT `usable` with source
`externalEnabler` or `preexisting`. On the A15 / iOS 27 device, TXM should keep
JIT `not usable` (`txmEnforced`) regardless. This case is to find out the ground
truth, not to confirm a fixed expectation.

1. Install LiveContainer (via AltStore, SideStore, or TrollStore) and load `Eikon-<v>.ipa` into it as a guest app.
2. If you use a JIT source with LiveContainer (SideStore/JITStreamer, or its TrollStore JIT), enable it for the guest, then launch Eikon inside LiveContainer.
3. File the report, and record in the notes:
   - the **Detected method** and the **Bundle ID** shown on the status screen (LiveContainer may run the guest under its own id)
   - whether JIT is **usable**, and the **source** and **CS_DEBUGGED** rows
   - the redacted **bundle path** and **home directory** in the report's evidence (these show how LiveContainer maps the guest)
4. If JIT is usable but the source says `externalEnabler`/`preexisting` rather than naming LiveContainer, that's expected for now — the report tells us whether a dedicated `liveContainer` install method and JIT source are worth adding.

## Filing

**Automated (recommended).** Trigger the `file-report` workflow with the report's JSON. It validates, files and commits the report for you. Because `workflow_dispatch` needs write access, only maintainers can run it.
- GitHub UI: **Actions → file-report → Run workflow**, paste the JSON.
- CLI: `gh workflow run file-report.yml -f report="$(cat report.json)"`.
- On device: a Shortcut that receives the shared report and calls that workflow via the GitHub API (with your own fine-grained token) makes it one tap.

**Manual.**
1. Export the report from the app (**Share report**, or **Copy report** and paste into a file).
2. Run `uv run scripts/file_device_report.py <path>` (or `-` for stdin). It validates the report, rejects unknown schema versions, and writes `device-reports/<date>-<model>-<method>-<hash>.json`. Refiling an identical report is a no-op.
3. Commit the filed reports. Pushing them is outward-facing, so ask the owner first.

## Expected results

| Device | Install | Expected JIT | Source or reason |
|---|---|---|---|
| iPad M2, 17.0 | TrollStore ipa, Open with JIT | usable | `trollStore` |
| iPad M2, 17.0 | Dopamine 3 | usable | `dopamine` |
| iPad M2, 17.0 | Dopamine 3, JIT off | not usable | `dopamineJITOff` |
| iPhone A15, 27.0 | AltStore | not usable | `txmEnforced` |
| either | LiveContainer | exploratory | `sideloaded`/`unknown`; JIT per LiveContainer's source |

## Follow-ups from what the reports show

Each of these is a change that goes through normal review, and any new release is a new version:

- **Sileo didn't follow the redirect:** publish with `build_index.py`'s `--filename-mode relative`, committing the deb under `docs/debs/` while it's under 100 MB.
- **AltStore rejected a capability:** drop that key from `packaging/entitlements/ipa.plist` and note it in `packaging/entitlements/README.md`.
- **`uicache` needs `mobile`:** adjust `packaging/deb/postinst` and `prerm`.
- **Dopamine 3 unsupported on the iPad:** record the deb as desktop-verified only.
- **The TXM table was wrong for a CPU family:** correct the CPU-family table in `Packages/EikonKit/Sources/EikonKit/TXMTable.swift`.
