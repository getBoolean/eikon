# 01 · Build, packaging, and JIT enablement

## Outcome (done 2026-09-28, v0.2.3)

Every "Done when" item is met, with device reports in `device-reports/`. The build differs from the scope below in these ways, all owner decisions or device findings:

- **Two artifacts, not three.** The `.tipa` was dropped: one `.ipa` serves AltStore and TrollStore. The deb's package id is `com.getboolean.eikon.rootless`, so it can sit next to the ipa's `com.getboolean.eikon`.
- **No submodules.** Upstreams come from fork releases pinned in `third_party/deps.toml`.
- **No `no-sandbox`.** On TrollStore it got the app killed at exec. Both packages run sandboxed. The deb carries `container-required` for its own id to get a normal data container.
- **TrollStore detection reads entitlements, not the `_TrollStore` file.** TrollStore re-signs the ipa with `container-required` set to its bundle id. The marker file was never visible on the test iPad.
- **TXM comes from a CPU-family table only.** The firmware read in `/private/preboot` needed an unsandboxed process.
- **Dopamine was tested on iPadOS 17.0**, not Dopamine 2 on iOS 15–16.

The rest of this file is the original spec.

## Purpose

Create the Eikon project from nothing. The result builds one source tree, as one app binary at one version, into three installable artifacts, signs each so it loads under its install method, turns JIT on automatically where the install method allows it, and reports whether the running process has JIT. Every later split builds on this.

## Read first

- `planning/requirements.md`: Goals 4, 7, 8. "Builds and JIT", "Packaging", "App" (credits), "Constraints" (no exploit, target devices, install-method table), "Operational requirements" (signing), and "Decisions".
- `planning/deep_project_interview.md`.
- `planning/handoff.md`: the current state of the `eikon-source` Sileo repo. What landed, what's missing, and why Pages isn't serving.
- Do not use `planning/old-stages/` as input (owner's decision).

## Current state

The repo holds only `README.md`, `.gitignore`, and `planning/`. There is no source, no build system, no submodule, and no `LICENSE`.

## Scope

**In:**
- Repo layout. Conventions for third-party code: pinned submodules under a single directory, changes only as patch files, and a script that applies the patches reproducibly.
- The build system and UI stack. **Open decision, for /deep-plan:** Xcode project vs Theos vs xcodebuild wrapped in scripts, and UIKit vs SwiftUI. The owner left it open. The chosen system must also cross-compile C/C++ upstreams (FEX, Wine, Kirikiroid2) later.
- **One build** (owner's decision, 2026-09-27, replacing the earlier main and no-JIT flavors). All three artifacts carry the same app binary and differ only in entitlements and packaging. What needs JIT is decided at run time from the JIT API.
- Three artifacts at the same version:
  - Dopamine rootless deb: package id `com.getboolean.eikon`, `iphoneos-arm64`, installed under `/var/jb`. Signed ad-hoc with `ldid`.
  - `Eikon.tipa` for TrollStore.
  - `Eikon.ipa` for AltStore, signed by AltStore at install.
- Entitlements for the deb and `.tipa`: `com.apple.private.security.no-sandbox`, and the `.tipa` keeps its data container. No `com.apple.private.persona-mgmt`, no entitlement TrollStore bans, and **no `dynamic-codesigning`** (it crashes on launch on iOS 15+ with A12+). If `platform-application` is added, check whether `com.apple.private.security.storage.AppDataContainers` is also needed. Consider entitlements that later splits need, such as raised memory limits and extended virtual addressing, and record which install methods can honor them.
- Automatic JIT:
  - **Dopamine:** use the mechanism Dopamine provides, with no setup or extra tool for the user. /deep-plan must research what Dopamine 2 exposes for this.
  - **TrollStore (2.0.12+):** at launch without JIT, open `apple-magnifier://enable-jit?bundle-id=<id>` so TrollStore relaunches the app with JIT, the way UTM and PojavLauncher do. Guard against relaunch loops, and handle older TrollStore versions cleanly.
  - **AltStore:** never requests JIT. It detects JIT if an enabler (such as StikDebug) has given it. On TXM devices (iOS 26+), `CS_DEBUGGED` alone is reported as not usable.
- A JIT detection API that later splits can call. It reports whether the process has usable JIT and which method provided it, and it checks by actually running a generated function, not only by reading flags. Later splits choose routes from it.
- A device-report facility: every device result records device, iOS version, chip, install method, and build. Later splits reuse it for their device gates.
- Licensing: a `LICENSE` file (GPL-3.0-or-later), `THIRD_PARTY_NOTICES`, a licenses directory, and an automated check that fails if any submodule lacks a credit entry and a license file. The in-app credits screen is 02's, but the data pipeline starts here.
- Publishing to `https://github.com/getBoolean/eikon-source` through GitHub Pages: `Packages`, `.gz`/`.bz2`, `Release`, depiction, icon, the deb, and a Pages workflow. Only package files go there, never app source. Finish what the handoff says is missing, and treat the handoff's `1.0.0` byte counts as belonging to a package that no longer exists.

**Out:** the library UI and game features (02), and anything that runs guest code.

## Provides to later splits

- The build system, the per-artifact packaging, and the submodule and patch convention (all splits).
- The JIT enablement and detection API (05, 06, 13, 14).
- The device-report format (05 onward).
- The credits pipeline (every split that adds third-party code).
- Entitlement files for each install method (08 for memory limits, 05 and 07 for address space).

## Constraints to carry

- No exploit and no JIT bypass of Eikon's own. Eikon doesn't attach a debugger or call `ptrace` or task-for-pid. Relying on Dopamine's and TrollStore's mechanisms is intended.
- Target devices: Dopamine 2 on iOS 15.0–16.6.1, TrollStore up to iOS 17.0, AltStore on current iOS. TXM devices handle debugger-based JIT differently.
- No program titles anywhere.

## Done when

- One command (or CI job) produces the deb, `.tipa`, and `.ipa` at the same version.
- Each installs and launches on its install method, and shows its JIT state and how it got it. On Dopamine and TrollStore, JIT is on without any user action.
- The deb installs from `eikon-source` in Sileo after Pages is serving.
- The credits check passes, and fails when a submodule without a credit is added.
