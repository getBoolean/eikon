# Split 01 spec: build, packaging, and JIT enablement

This combines the following sources. Where they disagree, this file and the updated `requirements.md` win:
- the initial spec (`spec.md`)
- `planning/requirements.md`, updated 2026-09-27 for the one-build decision
- `claude-research.md`
- `claude-interview.md`

## 1. What this split delivers

Eikon starts from an empty repo. After this split:
- One command, or one CI job, builds **one app binary** at one version.
- It packages that binary three ways:
  - the Dopamine rootless deb
  - `Eikon.tipa` for TrollStore
  - `Eikon.ipa` for AltStore
- The app turns JIT on automatically where the install method allows it.
- The app reports whether the process has **usable** JIT, where it came from, and why not when it doesn't.
- It exports a device report.
- The deb installs in Sileo from `https://getboolean.github.io/eikon-source/`.
- A credits check guards every third-party component that later splits add.

It builds no game features and runs no guest code. Split 02 owns the library UI and the credits screen.

## 2. Decisions (owner, 2026-09-27)

| Topic | Decision |
|---|---|
| Builds | **One build.** The artifacts differ only in entitlements, an Info.plist package-kind stamp, and packaging. Routes are chosen at run time from the JIT API. This replaces the earlier main and no-JIT flavors. |
| Build system | **XcodeGen `project.yml` + `.xcconfig` + a top-level Makefile** that calls scripts. The generated `.xcodeproj` is not committed. |
| UI | **SwiftUI** for app screens. UIKit view controllers will host render and input surfaces in later splits. |
| Minimum OS | **iOS 15.0** for all three artifacts. |
| `platform-application` | **Not used.** Considered, and recorded as not needed. |
| `.tipa` JIT | Include `get-task-allow`. TrollStore's enable-jit needs it. Developer Mode is already a prerequisite for these installs. |
| Dopamine | Detect the JIT that Dopamine 2.1+ grants at launch. There is no API call. |
| TrollStore | Open `apple-magnifier://enable-jit?bundle-id=com.getboolean.eikon` once when JIT is missing, poll, and time out. Offer a manual "Retry JIT" button. |
| AltStore | Never request JIT and offer no StikDebug button. Only detect. |
| TXM (iOS 26+) | Detect and report. On TXM devices, `CS_DEBUGGED` alone counts as "present but not usable". Blessing JIT pages is deferred to 05 and 14. |
| JIT missing on the deb or `.tipa` | Keep running. Show the likely cause and fixes for the install method. |
| Deb hosting | Debs are **GitHub Release assets on `eikon`**. `eikon-source` holds only the index files and Pages content. `Packages` uses absolute `Filename` URLs, which only Sileo supports. |
| CI and publishing | GitHub Actions builds on tags, creates the Release, and updates the `eikon-source` index through a deploy key. `make all` and `make publish` also work locally. |
| First version | **0.1.0**. It replaces the phantom `1.0.0` index entry, whose deb was never uploaded. |
| Device reports | The app exports JSON (copy or share). A script validates it and files it under `device-reports/`. Later splits add gate fields. |
| Tests | Swift Testing on the simulator, and pytest through uv for scripts. **Tests stay few and behavioral.** They must not lock in implementation details or hard-coded values. |

## 3. Constraints carried

- No exploit and no JIT bypass of Eikon's own. Eikon never attaches a debugger or calls `ptrace` or task-for-pid. Opening TrollStore's URL is relying on TrollStore, which is allowed.
- No `dynamic-codesigning`, `com.apple.private.cs.debugger`, `com.apple.private.skip-library-validation`, `com.apple.private.persona-mgmt`, or `platform-application` in any artifact.
- No program titles anywhere: code, depictions, reports, test names.
- **Target devices:**

  | Install | Supported range |
  |---|---|
  | Dopamine 2 | iOS 15.0–16.6.1 |
  | TrollStore | up to iOS 17.0 |
  | AltStore | current iOS |

- **Test hardware:**
  - iPad Pro 12.9" 6th gen (M2), iPadOS 17.0: for TrollStore, and for Dopamine 3 if it supports this device. Dopamine 3 uses the same check-in JIT mechanism as 2.1+.
  - iPhone 13 mini (A15), iOS 27.0: for AltStore. It has TXM.
  - Dopamine 2 proper is desktop-verified only.
- Upstream code: pinned submodules under one directory, with changes only as patch files. 01 adds no upstream code, but defines and proves the convention.

## 4. Requirements

### 4.1 Repo layout and conventions
- **Top level:**
  - `VERSION` (0.1.0), `LICENSE` (GPL-3.0-or-later text), `THIRD_PARTY_NOTICES.md` (generated, committed), `licenses/` (license texts by SPDX id)
  - `third_party/` (submodules plus the credits manifest), `patches/<component>/` (ordered patch files)
  - `project.yml`, `Config/*.xcconfig`, app sources, a local Swift package for testable core code
  - `packaging/`, `scripts/`, `device-reports/`, `tests/`, `.github/workflows/`
- **Submodule convention:**
  - Every upstream sits at `third_party/<name>`, pinned to a commit or tag, with `ignore = dirty`.
  - Changes live as `patches/<name>/NNNN-*.patch`.
  - `scripts/apply-patches` resets each submodule to its pinned commit and applies the patches in order. It is reproducible and idempotent, and it fails loudly on conflict. A companion command restores pristine trees.
- **Tools:**
  - Scripts call compilers through `xcrun`, because `~/.swiftly/bin` shadows `/usr/bin` on the owner's Mac.
  - A `make doctor` target reports missing tools: xcodegen, ldid-procursus, dpkg, uv.
  - `make bootstrap` installs them with Homebrew when the owner runs it.

### 4.2 Build
- XcodeGen generates the project.
- **Targets:**
  - the `Eikon` app, minimum iOS 15.0
  - a local Swift package `EikonKit`: C, ObjC and Swift core logic, including JIT detection, install-method detection, and the device report
  - a test target
- **Version stamping:**
  - `VERSION` sets `MARKETING_VERSION`.
  - The build number is `git rev-list --count HEAD`.
  - The git commit SHA is stamped into Info.plist.
- **Build step:** `xcodebuild archive … -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` produces one `.xcarchive`, and all three packages come from it.
- **Packaging stamps an Info.plist key with the package kind** (deb, tipa or ipa) before signing, so reports show what was installed.

### 4.3 Packaging and signing
- Signing uses ProcursusTeam ldid, in this order:
  1. nested code
  2. the bundle
  3. the main binary, with the per-artifact entitlements file and identifier `com.getboolean.eikon`
- **Per-artifact entitlements (`packaging/entitlements/`):**

  | Key | deb | tipa | ipa |
  |---|---|---|---|
  | `com.apple.private.security.no-sandbox` | ✓ | ✓ | – |
  | `get-task-allow` | – | ✓ | ✓ (the profile also provides it) |
  | `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | ✓ |
  | `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | ✓ |
  | `com.apple.private.memorystatus` | ✓ | ✓ | – |

  - The deb leaves out `get-task-allow`: Dopamine doesn't need it, and it would add a Developer Mode dependency.
  - A written entitlements note records, for each key, which install methods honor it, and records why `platform-application` is left out. Later splits add rows (08 for memory, 05 and 07 for address space).
- **`.ipa` and `.tipa`:** a zip of `Payload/Eikon.app`, with no AppleDouble files (`COPYFILE_DISABLE=1`, excluding `._*`, `.DS_Store` and `__MACOSX`).
- **Deb:**
  - Staged as `var/jb/Applications/Eikon.app`, plus `LICENSE` and `THIRD_PARTY_NOTICES.md` under `var/jb/usr/share/doc/com.getboolean.eikon/`.
  - Built with `dpkg-deb --root-owner-group -Zxz`.
  - Control fields:
    - identity: `Package: com.getboolean.eikon`, `Name: Eikon`, `Version: <VERSION>`
    - platform: `Architecture: iphoneos-arm64`, `Depends: firmware (>= 15.0)`, `Section: Games`
    - people: `Maintainer`, `Author`
    - size: `Installed-Size`
    - links: `Homepage`, `Icon`, `Depiction`, `SileoDepiction`
    - `Description`: no program titles
  - `postinst` runs `uicache -p` on the app when uicache exists, and `prerm` runs `uicache -u` on removal. Procursus's uikittools trigger normally covers this already; these are belt-and-braces.
- **Artifact names:** `dist/Eikon-<v>.ipa`, `dist/Eikon-<v>.tipa`, `dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb`, plus `SHA256SUMS`.
- **An artifact verifier** checks every package after it is built, and CI runs it:
  - the layout
  - the main binary's entitlements (the required keys are present, and no banned key is present)
  - that the version inside each package matches `VERSION`
  - no AppleDouble files

### 4.4 JIT enablement and detection (the API later splits call)
- **Status fields:**
  - `csDebugged`: from `csops(getpid(), CS_OPS_STATUS)`.
  - `txm`: present, absent or unknown. Checked from the preboot firmware file when readable, otherwise by a chip and iOS heuristic.
  - `probe`: not run, passed, or failed with its signal. Runs only when `csDebugged` is set and TXM doesn't block it. It maps an RX page, makes an RW alias with `vm_remap`, writes `mov w0,#42; ret`, invalidates the icache, and calls the page under a `sigsetjmp` guard that saves and restores signal handlers. It never uses `MAP_JIT`.
  - `usable`: `csDebugged` and the probe passed.
  - `source`: Dopamine, TrollStore, an external enabler, or none.
  - `reason`: a human-readable cause and fix when JIT isn't usable.
- **Install method:**
  - TrollStore: the `_TrollStore` or `_TrollStoreLite` marker in the bundle's container.
  - Dopamine: the resolved bundle path is under the jailbreak root (`/procursus/Applications/`, or `/var/jb`).
  - Sideloaded: `embedded.mobileprovision` is present.
  - Simulator.
  - Unknown.
  - The report shows both the stamped package kind and the detected install method.
- **Dopamine:** `CS_DEBUGGED` is set before `main()` when "Allow JIT in Apps" is on. When it's missing, the reason names the likely causes:
  - the toggle is off
  - Choicy has disabled tweak injection for Eikon
  - safe mode
  - Dopamine 2.0
- **TrollStore:**
  - The app opens the enable-jit URL at most once per process, when all of these hold:
    - the install is TrollStore
    - `CS_DEBUGGED` is missing
    - no attempt has been made within a persisted cooldown window, which guards against relaunch loops
  - It polls `CS_DEBUGGED` for a bounded time after returning to the foreground.
  - On timeout, the reason names:
    - TrollStore older than 2.0.12
    - the URL scheme disabled in TrollStore's settings
    - Developer Mode off
  - A "Retry JIT" button bypasses the cooldown.
  - TrollStore doesn't relaunch the app; it attaches to the running process and detaches.
- **AltStore:** detect only. The app re-checks when it returns to the foreground, since an enabler may attach at any time. Under TXM on iOS 26+, `CS_DEBUGGED` is reported as "present but not usable" and the probe isn't run.
- **API shape:** the status is observable, so SwiftUI updates when it changes. Later splits read `usable` to choose routes: FEX with JIT, Box64 or native without.

### 4.5 Device report
- **Contents:** JSON with a schema version and these fields:
  - app: version, build, commit, package kind
  - device: model identifier, chip (from a lookup table, "unknown" as fallback), CPU family
  - OS: name, version and build
  - install: detected method and the evidence for it
  - JIT: csDebugged, usable, source, probe, TXM, reason
  - memory: available memory at report time, as evidence of the memory entitlements
  - an open `gates` object that later splits fill
  - a timestamp
- **Privacy:** it never contains the user-assigned device name or anything about games.
- **In the app:** a "Copy report" action and a "Share report" action.
- **In the repo:**
  - `device-reports/schema.json`.
  - `scripts/file-device-report` validates a report against the schema and writes it under `device-reports/` with a name built from the date, model, install method and a short hash.

### 4.6 App (minimal)
- One SwiftUI status screen showing:
  - version, build and package kind
  - install method
  - JIT state, source, probe and TXM
  - the reason when JIT isn't usable, with fixes
  - device, chip and iOS
  - available memory
  - "Retry JIT", shown only on TrollStore when JIT isn't usable
  - Copy and Share report
- An original app icon.
- The credits JSON is bundled, but 02 builds the credits screen.

### 4.7 Licensing and credits
- **Files:** `LICENSE` holds the GPL-3.0-or-later text. `licenses/<SPDX>.txt` holds each license text used.
- **Manifest:** `third_party/credits.toml`, which the Python standard library can parse without dependencies. Each entry has name, path, upstream URL, pinned revision, SPDX license expression, license files, and nested sub-licenses.
- **The check fails when:**
  - a submodule in `.gitmodules` or a directory in `third_party/` has no entry
  - an entry points nowhere
  - a listed license file is missing
  - a license id has no text in `licenses/`
  - the committed `THIRD_PARTY_NOTICES.md` is stale
- **Generated outputs:** `THIRD_PARTY_NOTICES.md` and an acknowledgements JSON bundled in the app, which 02 renders. The notices also ship in the deb.
- **Starting state:** the manifest is empty in 01. It is proven by behavioral tests: a credited submodule passes and an uncredited one fails.

### 4.8 Publishing to `eikon-source`
- `eikon-source` holds only package metadata and Pages content: `docs/` with `Release`, `Packages`, `Packages.xz`, `Packages.zst`, `depiction.json`, `index.html`, `CydiaIcon.png`, `icon.png` and `.nojekyll`, plus `README.md`. There is no app source, no scripts, and no debs.
- **Pages:** deploy from branch `main`, folder `/docs`. This replaces the spec's "Pages workflow": no workflow file is needed, which avoids the earlier workflow-write failure and keeps the repo to package files only. Turning Pages on is a one-time step the owner runs or approves.
- **The index generator lives in `eikon`** (`scripts/repo/`). It:
  1. Reads the deb.
  2. Writes a `Packages` stanza whose `Filename` is the absolute GitHub Release asset URL.
  3. Compresses the index.
  4. Writes `Release` with correct `MD5Sum:`/`SHA256:` sections (with colons), `Architectures: iphoneos-arm64` and `Components: main`, listing only files that exist.
  5. Renders the depiction and index page from templates carrying the version.
  - It keeps only the latest version.
- **Fixes to the existing files:**
  - remove the stale `1.0.0` entry
  - fix the missing colons in `Release`
  - remove obsolete text (demo names, "Wine under FEX", "not a live source" once it is live)
- **CI:** on a `v*` tag, CI:
  1. Asserts the tag equals `v$(VERSION)`.
  2. Builds, packages and verifies.
  3. Creates the GitHub Release with the three artifacts and `SHA256SUMS`.
  4. Checks out `eikon-source` with an SSH deploy key secret, regenerates `docs/`, and commits and pushes.
- **Local:** `make publish` does the same from the Mac using `gh`.

### 4.9 Tests (few, behavioral)
- **Swift Testing:**
  - The JIT decision logic with injected inputs: install method, csDebugged, TXM, probe outcome, prior attempts. It checks whether JIT counts as usable, whether the TrollStore URL is opened or suppressed, and that each unusable case yields a reason.
  - Install-method detection from a fake bundle layout.
- **pytest:**
  - the credits check (passes when credited, fails when not)
  - the patch script (applies cleanly, is idempotent, fails loudly on conflict)
  - the repo index (the `Release` hashes and sizes match the files it lists, and the `Packages` stanza points at the deb)
  - the device-report filer (accepts a valid report, rejects an invalid one)
  - the version guard (a mismatch fails)
- **Not tests, but verification:** the artifact verifier runs on real artifacts in CI.
- **Device checks** are manual and recorded as device reports.

## 5. Done when
1. `make all` locally and the tag CI job both produce the deb, `.tipa` and `.ipa` at the same version, and the verifier passes on all three.
2. **iPad (TrollStore, iPadOS 17.0):** the `.tipa` installs and launches, and JIT becomes usable with no user action. The report is filed.
3. **iPad (Dopamine 3, if it supports the device):** the deb installs from `eikon-source` in Sileo, launches, and JIT is usable at launch. The report is filed. If Dopamine 3 can't run on the device, the deb is desktop-verified only and the report says so.
4. **iPhone 13 mini (AltStore, iOS 27):** the `.ipa` installs and launches, and reports JIT not usable with reason `txmEnforced`, with or without an enabler. The report is filed.
5. `https://getboolean.github.io/eikon-source/` serves the repo, and Sileo lists 0.1.0.
6. The credits check passes on the repo and fails when an uncredited submodule is added.

## 6. Provides to later splits
- The build system and packaging, the submodule and patch convention, and the version stamp.
- The JIT status API (`usable`, `source`, `reason`, `txm`) for route choice (02, 05, 06, 13, 14).
- The device-report format and filer, with an extensible `gates` object (05 onward).
- The credits manifest, check and generators (every split that adds third-party code).
- The per-artifact entitlements files and the entitlements note (08 memory, 05 and 07 address space).
