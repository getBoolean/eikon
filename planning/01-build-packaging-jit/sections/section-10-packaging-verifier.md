# Section 10: Packaging, signing and the artifact verifier

## Goal

Turn the one Release archive of the app into three install artifacts, each signed with its own entitlements:

- `dist/Eikon-<v>.ipa` for AltStore
- `dist/Eikon-<v>.tipa` for TrollStore
- `dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb` for Dopamine rootless

Then prove with a verifier script that they are correct and contain the same binary. This section also extends CI so every push archives, packages and verifies.

When this section is done, `make archive package verify` succeeds locally and in CI, and `dist/` holds the three artifacts plus `SHA256SUMS`.

## Background

Eikon uses **one build**. The three artifacts differ only in:

- their entitlements
- one Info.plist stamp, `EKPackageKind` (`deb`, `tipa` or `ipa`; the development build has `development`)
- their container format

Routes are chosen at run time, so the main executable must be the same across all three. The verifier enforces that.

What each install method needs:

- **Dopamine 2.1+ / 3.x (deb):** Dopamine grants JIT to apps under its jailbreak root's `Applications` directory before `main()`, with no entitlement needed. The app is installed at `/var/jb/Applications/Eikon.app`. The deb leaves out `get-task-allow`: Dopamine doesn't need it, and on iOS 16+ it would require Developer Mode.
- **TrollStore 2.0.12+ (tipa):** JIT comes from TrollStore's `apple-magnifier://enable-jit?bundle-id=…` URL. TrollStore's helper attaches to the running app briefly, which needs `get-task-allow`. On iOS 16+, an app with `get-task-allow` needs **Developer Mode** on. That is a documented `.tipa` requirement.
- **AltStore (ipa):** AltStore re-signs with the developer profile's entitlements (which include `get-task-allow`) and replaces whatever entitlements the ipa carries. The ipa still lists the public capability keys so AltStore requests those App ID capabilities. Free accounts may rewrite the bundle id.

**Constraints that apply here:**

- **Forbidden in every artifact:** `dynamic-codesigning`, `com.apple.private.cs.debugger`, `com.apple.private.skip-library-validation`, `com.apple.private.persona-mgmt`, `platform-application`.
  - `dynamic-codesigning` crashes on iOS 15+ A12+ and TrollStore bans it.
  - `platform-application` is not used. It brings a stricter IOKit sandbox (Metal would need GPU exceptions), it can cost the app its data container, and nothing needs it.
- **Signing tool:** ProcursusTeam **ldid** (Homebrew formula `ldid-procursus`, not `ldid`, which is saurik's version). One bundle-level signing call signs nested code first and seals resources correctly.
- **Tooling:** scripts call Apple tools through `xcrun` where a compiler or SDK tool is involved, because `~/.swiftly/bin` precedes `/usr/bin` on PATH on the dev Mac. Python scripts run through `uv run` on Python 3.12 and use **only the standard library**.
- **No program titles** anywhere: the deb description, READMEs, and script output.
- iOS 15.0 minimum; `arm64` only.

## Dependencies

- **Section 02 (Xcode project):** provides `project.yml`, the `Eikon` scheme, `App/Info.plist` with `CFBundleShortVersionString = $(MARKETING_VERSION)`, `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`, `EKGitCommit`, and `EKPackageKind = development`, bundle id `com.getboolean.eikon`, and the minimal `.github/workflows/ci.yml` (a `scripts` job and a `build` job that currently runs `make test-swift`).
- **Section 04 (credits pipeline):** provides `make generated` (which writes `build/generated/Acknowledgements.json`), the committed `THIRD_PARTY_NOTICES.md`, and the XcodeGen switch between the generated and the placeholder acknowledgements resource.
- **Section 01 (skeleton):** provides `VERSION`, `LICENSE`, the `Makefile` (with stub targets `archive`, `ipa`, `tipa`, `deb`, `package`, `verify`, `all` that this section replaces with real recipes), `make project`, and `scripts/doctor.sh` (which already checks for `ldid-procursus`, `dpkg-deb`, `zstd`, `xz`).

This section blocks section 11 (repo publishing reads the deb from `dist/`) and section 12 (the release workflow runs `make all`).

## Tests first

**No unit tests for this section.** This is the owner's rule applied: packaging has no behavioral logic worth pinning with unit tests, and tests must never pin file contents, constants or string texts. The check is the verifier itself (`scripts/verify_artifacts.py`), which runs on **real artifacts**:

- in CI on every push and pull request (`make test-swift archive package verify`)
- locally on every `make all`

The verifier's expectations come from `packaging/entitlements/*.plist` and `VERSION`. It must not duplicate constants such as the version string or entitlement keys in its own code, except the forbidden-key list, which is a policy list rather than an expectation about a file.

**One-time build-time check (not a kept test):** on the first CI run of the extended workflow, prove that the verifier catches a forbidden key. In a scratch branch, temporarily add `dynamic-codesigning` to `packaging/entitlements/tipa.plist`, push, and confirm the `build` job fails in the verify step with a message naming the tipa and the key. Delete the scratch branch afterwards. Do the same kind of spot check locally for one other failure class if convenient (for example, drop a `.DS_Store` into a staged bundle before zipping). None of this is committed.

## Files to create or modify

| Path | Action |
|---|---|
| `scripts/archive.sh` | create |
| `scripts/package.sh` | create |
| `scripts/verify_artifacts.py` | create |
| `packaging/entitlements/deb.plist` | create |
| `packaging/entitlements/tipa.plist` | create |
| `packaging/entitlements/ipa.plist` | create |
| `packaging/entitlements/README.md` | create |
| `packaging/deb/control.in` | create |
| `packaging/deb/postinst` | create (mode 0755 in git) |
| `packaging/deb/prerm` | create (mode 0755 in git) |
| `Makefile` | replace the stub recipes for `archive`, `ipa`, `tipa`, `deb`, `package`, `verify`, `all` |
| `.github/workflows/ci.yml` | extend the `build` job |
| `README.md` | add the install-method requirements (tipa needs Developer Mode on iOS 16+) |

## Implementation

### 1. Archive: `scripts/archive.sh`

Bash, `set -euo pipefail`, run from the repo root. Steps:

1. Run `make project` (which runs `make generated`, then `xcodegen generate`).
2. Archive:
   ```
   xcodebuild archive -project Eikon.xcodeproj -scheme Eikon -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/Eikon.xcarchive CODE_SIGNING_ALLOWED=NO
   ```
3. **Acknowledgements guard:** fail with a clear message if `build/generated/Acknowledgements.json` is missing. A Release build must never ship the placeholder acknowledgements.
4. **arm64-only guard:** walk `build/Eikon.xcarchive/Products/Applications/Eikon.app`, find every Mach-O file (check magic bytes, or use `file`), and list its architectures with `xcrun lipo -archs`. If a fat binary contains arm64 plus other slices, thin it in place with `xcrun lipo -thin arm64`. If any Mach-O has no arm64 slice, or still has a non-arm64 slice after thinning, fail and name the file. There are no nested Mach-O files in this split; the guard is for later splits that add frameworks.

Output: `build/Eikon.xcarchive`. Makefile: `archive: project` then `scripts/archive.sh` (or let the script call `make project` itself; pick one so the project isn't generated twice).

### 2. Entitlements: `packaging/entitlements/`

Three property lists, one per kind:

| Key | deb | tipa | ipa |
|---|---|---|---|
| `com.apple.private.security.no-sandbox` | true | true | – |
| `get-task-allow` | – | true | true |
| `com.apple.developer.kernel.increased-memory-limit` | true | true | true |
| `com.apple.developer.kernel.extended-virtual-addressing` | true | true | true |
| `com.apple.private.memorystatus` | true | true | – |

None of them contains a forbidden key.

`packaging/entitlements/README.md` records:

- **Each key:** its purpose and which install methods honour it (the "honoured-by" table). For example, `no-sandbox` is honoured by Dopamine and TrollStore installs; the public `com.apple.developer.kernel.*` keys are App ID capabilities that AltStore requests from the developer account; `get-task-allow` is what TrollStore's enable-jit needs to attach.
- **What is unverified:**
  - whether the memory keys have any effect under Dopamine ad-hoc signing
  - whether an AltStore free team can be granted `increased-memory-limit` and `extended-virtual-addressing`

  The evidence for both is the device report's `memory.availableBytes` and the result of the first ipa install. If a free team can't be granted a capability and the install fails, the fix is to drop that key from `ipa.plist` and note it here.
- **Why `platform-application` is not used** (the reasons in Background).
- **The forbidden list**, with one line each on why.
- **The `.tipa` Developer Mode requirement:** the tipa carries `get-task-allow`, so on iOS 16+ it needs Developer Mode on. The deb leaves the key out for exactly this reason.
- A note that later splits add rows here: 08 for memory, 05 and 07 for address space.

### 3. Deb metadata: `packaging/deb/`

**`control.in`** with placeholders `@VERSION@` and `@INSTALLED_SIZE@`:

- `Package: com.getboolean.eikon`
- `Name: Eikon`
- `Version: @VERSION@`
- `Architecture: iphoneos-arm64`
- `Depends: firmware (>= 15.0)`
- `Section: Games`
- `Maintainer: getBoolean <https://github.com/getBoolean>`
- `Author: getBoolean`
- `Installed-Size: @INSTALLED_SIZE@`
- `Homepage: https://github.com/getBoolean/eikon`
- `Icon: https://getboolean.github.io/eikon-source/icon.png`
- `Depiction: https://getboolean.github.io/eikon-source/`
- `SileoDepiction: https://getboolean.github.io/eikon-source/depiction.json`
- `Description:` short and honest, with no program titles (for example, that the app is an early build that reports JIT and device status).

**Maintainer scripts** (`#!/bin/sh`, POSIX, mode 0755):

- Both prepend `/var/jb/usr/bin:/var/jb/bin` to `PATH` and locate `uicache` with `command -v uicache`.
- `postinst`: on `configure`, run `uicache -p /var/jb/Applications/Eikon.app`.
- `prerm`: on `remove` only (not `upgrade`), run `uicache -u /var/jb/Applications/Eikon.app`.
- Both exit 0 when `uicache` is absent. Procursus's uikittools trigger on `/var/jb/Applications` normally covers registration anyway.
- Leave a comment that whether `uicache` must run as `mobile` on iOS 15+ is checked on the first Dopamine install (an open point, adjusted then if needed).

### 4. Packaging: `scripts/package.sh ipa|tipa|deb`

Bash, `set -euo pipefail`. Takes one kind argument. Reads the version from `VERSION` (no hard-coded version anywhere).

**Common steps, per kind:**

1. Create a fresh stage directory under `build/stage/<kind>/` (remove any previous one). Copy the app with `COPYFILE_DISABLE=1 ditto build/Eikon.xcarchive/Products/Applications/Eikon.app <stage>/Eikon.app`. Fail clearly if the archive is missing.
2. Stamp the kind: `/usr/libexec/PlistBuddy -c "Set :EKPackageKind <kind>" <stage>/Eikon.app/Info.plist`.
3. Sign once at bundle level:
   ```
   ldid -S<packaging/entitlements/<kind>.plist> -I<bundle id read from the staged Info.plist> <stage>/Eikon.app
   ```
   Procursus ldid signs nested code first and seals resources (`_CodeSignature/CodeResources`). The bundle id is read from `CFBundleIdentifier` in the staged Info.plist, not hard-coded.
   - **Fallback:** if it turns out that ldid applies the entitlements to nested Mach-O files as well, first sign each nested Mach-O with plain `ldid -S` (no entitlements), then run the bundle-level call. The verifier's "nested code carries no entitlements" check decides which variant is correct; there is no nested code in this split, so the question becomes live in later splits.
4. Read the version back: `CFBundleShortVersionString` from the staged Info.plist must equal `VERSION`, otherwise fail.

Make sure `ldid` on PATH is the Procursus variant (the same test `doctor.sh` uses) and fail with a pointer to `make doctor` otherwise.

**ipa and tipa:**

- Build `Payload/Eikon.app` in the stage, then from the stage directory:
  ```
  zip -qr -X --symlinks <out> Payload -x '*/._*' '*/.DS_Store' '__MACOSX/*'
  ```
- Outputs: `dist/Eikon-<v>.ipa` and `dist/Eikon-<v>.tipa`.
- These zips are not byte-reproducible (they carry mtimes), and nothing assumes they are.

**deb:**

1. Stage `var/jb/Applications/Eikon.app` (the signed app). Copy `LICENSE` and `THIRD_PARTY_NOTICES.md` into `var/jb/usr/share/doc/com.getboolean.eikon/`.
2. Write `DEBIAN/control` from `control.in`, replacing `@VERSION@` with `VERSION` and `@INSTALLED_SIZE@` with the `du -sk` total of the staged `var` directory. Install `postinst` and `prerm` into `DEBIAN/` with mode 0755.
3. `chmod -R u=rwX,go=rX` the stage (then re-assert 0755 on the maintainer scripts if needed; `u=rwX` keeps them executable because they already have `x`).
4. Build:
   ```
   SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) dpkg-deb --root-owner-group -Zxz -b <stage> dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb
   ```

**`make package`** runs `package.sh` for all three kinds, then writes `dist/SHA256SUMS` over the three artifacts (`shasum -a 256` with names relative to `dist/`, so `cd dist && shasum -a 256 -c SHA256SUMS` works). Clear stale artifacts from `dist/` first so `SHA256SUMS` and the verifier only see this build.

**Makefile recipes** (replace the stubs from section 01):

| Target | Recipe |
|---|---|
| `archive` | `project`, then `scripts/archive.sh` → `build/Eikon.xcarchive` |
| `ipa` / `tipa` / `deb` | `scripts/package.sh <kind>` → `dist/` |
| `package` | all three, plus `dist/SHA256SUMS` |
| `verify` | `uv run scripts/verify_artifacts.py dist/` |
| `all` | `check test archive package verify` |

### 5. Verifier: `scripts/verify_artifacts.py dist/`

Python 3.12, standard library only, run through `uv run`. Invoked with the `dist/` directory. It finds the three artifacts by pattern (exactly one of each kind; fail if any is missing or duplicated), extracts each into its own temporary directory, runs every check, and **reports all failures** (grouped by artifact) before exiting non-zero. On success it prints a short summary and exits 0.

External tools it may call: `dpkg-deb` (`-x` to extract, `-f` to read control fields) and `ldid -e` (to dump entitlements). Everything else, including zip extraction, plist parsing (`plistlib`), and Mach-O parsing (`struct`), is done in Python.

**Where expectations come from:**

- The version: the repo's `VERSION` file.
- The entitlements expected per kind: `packaging/entitlements/<kind>.plist`.
- The artifact kind: from which artifact is being checked.
- The forbidden-key list: the one policy list in the script.

Nothing else is duplicated as a constant.

Suggested structure (signatures and docstrings only):

```python
def extract(artifact: Path, kind: str, dest: Path) -> Path:
    """Extract the artifact; return the path to Eikon.app inside it."""

def check_layout(kind: str, root: Path) -> list[str]:
    """Container layout and, for the deb, control fields."""

def check_version_and_stamp(kind: str, app: Path, version: str) -> list[str]:
    """CFBundleShortVersionString and EKPackageKind."""

def check_hygiene(root: Path) -> list[str]:
    """No AppleDouble files, .DS_Store or __MACOSX anywhere."""

def check_signature(kind: str, app: Path, expected: dict) -> list[str]:
    """Entitlements, forbidden keys, resource seal, nested code."""

def binary_identity(executable: Path) -> tuple[bytes, dict[str, str]]:
    """LC_UUID and a sha256 per segment, excluding __LINKEDIT."""

def main(argv: list[str]) -> int: ...
```

**Checks:**

*Layout and control*

- The ipa and the tipa each contain exactly one `Payload/Eikon.app` and nothing outside `Payload/`.
- The deb has the app at `var/jb/Applications/Eikon.app`, and no file or directory outside `var/jb/` (apart from the root `.`, `var` and `var/jb` directories themselves).
- The deb control (`dpkg-deb -f`) has `Architecture: iphoneos-arm64`, `Package` equal to the app's `CFBundleIdentifier`, and `Version` equal to `VERSION`.

*Version and stamp*

- `CFBundleShortVersionString` equals `VERSION` in all three.
- `CFBundleVersion` is identical across all three artifacts.
- `EKPackageKind` equals the artifact's kind.

*Hygiene*

- No `._*`, `.DS_Store` or `__MACOSX` entry anywhere. For zips, check the entry names; for the deb, walk the extracted tree.

*Signatures and entitlements*

- The main executable (named by `CFBundleExecutable`) has entitlements (`ldid -e`, parsed with `plistlib`) containing **every** key from its kind's entitlements file with the **same value**.
- It contains **no forbidden key**. Report each forbidden key found.
- Its code directory includes a resource-directory hash: parse the `LC_CODE_SIGNATURE` blob, find the CodeDirectory, and check it has at least 3 special slots and a non-zero hash in the resource-directory slot (special slot 3, `CSSLOT_RESOURCEDIR`).
- `_CodeSignature/CodeResources` exists in the bundle.
- Every **nested** Mach-O in the bundle (any Mach-O file other than the main executable, found by magic bytes) is signed (has `LC_CODE_SIGNATURE`) and carries **no entitlements** (`ldid -e` output empty). There are none in this split; the check guards later splits.

*Same binary across artifacts*

- The three main executables have the same `LC_UUID`.
- For every segment except `__LINKEDIT` (which holds the signature and differs by entitlements), the sha256 of the segment's file bytes (`fileoff`/`filesize` from `LC_SEGMENT_64`) is identical across the three.
- Handle a fat file by reading its arm64 slice (after archive.sh there should be only one slice).

Error messages name the artifact, the check and the offending item (path, key or field), so a CI failure is readable without rerunning locally.

### 6. CI: extend `.github/workflows/ci.yml`

Keep the existing conventions from section 02: all actions pinned by commit SHA, top-level `permissions: contents: read`, `fetch-depth: 0` on checkout, newest installed Xcode through `DEVELOPER_DIR`.

Change the `build` job (`macos-latest`) to:

1. `brew install xcodegen ldid-procursus dpkg uv` (if the runner has Homebrew's `ldid` formula, it conflicts; unlink or uninstall it first).
2. `make test-swift archive package verify`.
3. Upload `dist/` as a workflow artifact (with a SHA-pinned `actions/upload-artifact`).

This workflow never publishes. Publishing belongs to section 12's `release.yml`.

### 7. README

Add, under install methods, that:

- the deb is for Dopamine (rootless) and needs no Developer Mode
- the tipa needs **Developer Mode on iOS 16+** because it carries `get-task-allow` for TrollStore's enable-jit
- the ipa is for AltStore, which replaces the entitlements with the profile's

## Done when

- `make archive package verify` succeeds on the dev Mac (after `make doctor` passes) and in the CI `build` job, and `dist/` holds the ipa, the tipa, the deb and `SHA256SUMS`.
- `cd dist && shasum -a 256 -c SHA256SUMS` passes.
- The one-time forbidden-key spot check made CI fail in the verify step, and the scratch branch is gone.
- No forbidden entitlement appears in any artifact, and no program title appears in any file this section adds.

---

## Implementation notes (as built)

Files: `scripts/{archive,package}.sh`, `scripts/verify_artifacts.py`, `packaging/entitlements/{deb,tipa,ipa}.plist` and their README, `packaging/deb/{control.in,postinst,prerm}`, the Makefile recipes, the CI build job, and the README install notes.

Verified on the dev Mac: `make all` passes; `dist/` holds the ipa, tipa, deb and `SHA256SUMS`; `cd dist && shasum -a 256 -c SHA256SUMS` passes. The ipa and tipa carry `get-task-allow`; the deb does not. `EKPackageKind` is stamped per artifact. Negative checks all fail as they should, naming the artifact and the offender: a forbidden `dynamic-codesigning` in the tipa, a planted `.DS_Store`, and a deb leaking `get-task-allow`.

From the code review:
- The verifier requires each artifact's entitlement set to **equal** its plist exactly, not just contain it, so a leaked or missing per-kind key fails. `ldid -e` was confirmed to emit exactly the signed plist's keys.
- `make package` clears `dist/` first, and `ipa`/`tipa`/`deb`/`package` depend on `archive`, so parallel make can't reorder them.
- The deb layout check reports every path outside `var/jb/`.

Open points recorded in the entitlements README: whether Dopamine honours the memory keys, and whether an AltStore free team can be granted the `kernel.*` capabilities. Both are resolved by the first installs and device reports.

The archive's arm64 guard and the verifier's nested-Mach-O checks have nothing to act on in this split (a single flat app bundle); they guard the later splits that add frameworks.

The review trail is in `../implementation/code_review/section-10-*.md`.
