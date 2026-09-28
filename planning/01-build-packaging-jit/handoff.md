# Handoff: split 01 — TrollStore launch crash

Date: 2026-09-28. For the next session picking this up.

## Where things stand

- Sections 01–12 of split 01 are implemented. `v0.1.0` is released on GitHub and published to the Sileo source at `https://getboolean.github.io/eikon-source/`.
- **v0.2.0** drops the `.tipa` and ships two artifacts, and the ipa no longer carries `no-sandbox`:
  - `Eikon-<v>.ipa`, bundle id `com.getboolean.eikon`, for AltStore **and** TrollStore
  - `com.getboolean.eikon.rootless_<v>_iphoneos-arm64.deb`, for Dopamine
- The owner pushes commits manually. Nothing pushes automatically. Commits after `75213c1` may not be on GitHub yet.
- Device reports: `.github/workflows/file-report.yml` files a report from pasted JSON (Actions → file-report → Run workflow). One report is filed so far: AltStore ipa on the iPad, JIT usable (Dopamine grants it), probe passed.

## Open problem: the TrollStore build crashes on launch

**Symptom.** The v0.1.0 `.tipa`, installed with TrollStore on the iPad Pro 12.9" M2 (iPadOS 17.0, Developer Mode on, Dopamine present), crashes **instantly, before any UI, on every launch**. The Dopamine deb was **not** installed at the time, so this is not a bundle-id collision.

**What's ruled out:**
- The JIT probe. It runs inside `EikonApp.init()`, and a probe crash would let the second launch survive through the crash sentinel. The same binary also ran the probe successfully as the AltStore ipa.
- Developer Mode (it was on).
- A code bug in general. The AltStore ipa is the same binary and works.

**Leading hypothesis.** AMFI kills the process at launch because of an entitlement. TrollStore keeps the entitlements we embed; AltStore throws them away when it re-signs. So the tipa ran with entitlements the working ipa never had:
- `com.apple.private.security.no-sandbox`
- `com.apple.private.memorystatus`
- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`
- `get-task-allow` (safe: AltStore's profile has it too, and that install works)

**Why it blocked the release.** The v0.2.0 ipa was going to embed this same set. `no-sandbox` is removed from `ipa.plist` in the v0.2.0 release; the owner still has to confirm a TrollStore launch.

**Evidence (2026-09-28, iPad still on 17.0, Developer Mode enabled).** No crash report. A launch after this handoff was written does show up in a log archive. SpringBoard's launch of `com.getboolean.eikon` returns `RBSRequestErrorDomain` code 5, "Launched process exited during launch," and launchd reports `exited due to SIGKILL` in the same millisecond the process is spawned. The kernel line is a Sandbox `hook..execve()` kill: `outside of container && not a driver && !i_can_has_debugger`. AMFI logs `App Store Fast Path` for `…/Eikon.app/Eikon` at that instant, and runningboard logs `No personas found` for `com.getboolean.eikon`. It retries about once a second. The sandbox message's process name for those pids is not `Eikon`. An older `Eikon` pid stays suspended with `CS_DEBUGGED` set; it is not the process these launches create.

That names a sandbox rule, not a plist key. `outside of container` matches `com.apple.private.security.no-sandbox` (and the missing persona). `not a driver` matches the deliberate lack of `platform-application`. `!i_can_has_debugger` means `get-task-allow` is not in effect at exec, even though Developer Mode is on and the key is in `ipa.plist`. The rule needs all three, so dropping `no-sandbox` is the first bisect. `get-task-allow` stays.

## How to record the logs

### Before starting
1. Plug the iPad into this Mac over USB, unlock it, and trust the computer.
2. Confirm it's visible: `idevice_id -l` should print the UDID (`00008112-00105921012BC01E`). `xcrun devicectl list devices` shows simulators too; ignore the "simulated" rows.
3. Make sure a TrollStore install is present. If it isn't, build one (`make archive package`) and install `dist/Eikon-<v>.ipa` **with TrollStore**. Remove any AltStore copy first, since both use `com.getboolean.eikon`.

### Option A — live capture while launching (recommended)
Run the capture in the background (the Bash tool's `run_in_background`). macOS has no `timeout` command; stop the capture by killing the background task.

```sh
S=<session scratchpad dir>
idevicesyslog -m eikon -o "$S/eikon-syslog.txt"
```

`-m eikon` keeps only lines that contain "eikon" (the match is case-sensitive, so it misses "Eikon"). That can drop the kernel's AMFI line, so for the first attempt capture unfiltered but quieter:

```sh
idevicesyslog -q -o "$S/eikon-syslog.txt"
```

Then:
1. Ask the owner to tap the TrollStore Eikon icon two or three times.
2. Wait for them to confirm, then stop the capture.
3. Search the capture:

```sh
grep -nE 'com\.getboolean\.eikon[^.]|Eikon\[|AMFI|CODESIGNING|Code Signature Invalid|entitlement|runningboardd.*eikon|SpringBoard.*eikon|kernel' "$S/eikon-syslog.txt" | grep -v ANL5UN4557
```

The `grep -v` removes the AltStore app. Look for a kernel or `amfid` line near the launch time that names an entitlement or says `CODESIGNING`, and for runningboardd reporting the exit reason (`termination reason` / `namespace CODESIGNING`).

### Option B — fetch the log afterwards (no timing needed)
The device keeps a log archive, so the owner can launch first and you can fetch later:

```sh
idevicesyslog archive "$S/eikon.logarchive.tar" --age-limit 600   # last 10 minutes
mkdir -p "$S/la" && tar -xf "$S/eikon.logarchive.tar" -C "$S/la"
log show --archive "$S/la"/*.logarchive --predicate 'eventMessage CONTAINS[c] "eikon" OR process == "amfid" OR eventMessage CONTAINS "CODESIGNING"' --last 10m
```

(If `log show` rejects the extracted path, point `--archive` at whichever directory in `$S/la` ends in `.logarchive`.)

### Privacy
A full device syslog contains personal data (account e-mail, other apps). Keep it in the scratchpad only, never commit it or quote it, and delete it when done. The old 218 MB capture at `/tmp/eikon-syslog.txt` should be deleted.

## If the log names the key
1. Remove that key from `packaging/entitlements/ipa.plist` and update `packaging/entitlements/README.md`.
2. Run `make all`. `make verify` compares each artifact's entitlements to its plist exactly.
3. The owner installs the new ipa with TrollStore, confirms it launches, and files a report.
4. The report also answers the second open question: whether a TrollStore-installed ipa is detected as `trollStore`. Detection looks for `_TrollStore` next to the bundle. "Open with JIT" detection already works: the report shows `csDebuggedSeen: atLaunch`.

## If the log doesn't name it: bisect
The 2026-09-28 capture did not name a key. `packaging/entitlements/ipa.plist` now drops only `com.apple.private.security.no-sandbox`. The owner installs that ipa with TrollStore and reports whether it launches. If it still dies the same way, drop `com.apple.private.memorystatus` next, then the two `com.apple.developer.kernel.*` keys, one at a time. `get-task-allow` stays, because TrollStore's JIT needs it.

## Other open items
- The owner said "dopamine deb id should not contain the version." The id (`Package:` and `CFBundleIdentifier`) is already `com.getboolean.eikon.rootless`, with no version. Only the `.deb` **filename** has one, by Debian convention. Confirm with the owner what they saw before changing anything.
- Releasing v0.2.0 is outward-facing. Get owner approval for each step, as for v0.1.0 (tag push, then approve the `eikon-source` environment in the release run).
- Device runbook cases still to run are in `device-reports/README.md`: TrollStore ipa, Dopamine deb, Dopamine with JIT off, AltStore on the iPhone (TXM), and LiveContainer.
