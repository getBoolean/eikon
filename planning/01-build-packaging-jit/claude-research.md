# Research: 01 · Build, packaging, and JIT enablement

Gathered 2026-09-27 from a read-only survey of the development Mac and the `eikon-source` repo, and from primary sources: the source code of Dopamine, TrollStore, UTM, Amethyst-iOS, PojavLauncher, LiveContainer, StikDebug, DolphiniOS, RetroArch, PPSSPP, Sileo, ProcursusTeam ldid and uikittools, and AltSign, plus their man pages and READMEs. **[unverified]** marks inference that no read source confirms.

---

## 1. Local toolchain (development Mac)

- **System:** macOS 27.0, Apple Silicon.
- **Xcode:** Xcode 27.0 (27A266a), Apple clang 21.0.0, Swift 6.4. The only iOS SDK is **iphoneos27.0**.
- **Build caveats:**
  - `~/.swiftly/bin` comes before `/usr/bin` on PATH. Build scripts must call tools through `xcrun`, not bare `clang`/`swift`.
  - The iOS 27 SDK needs `ac_cv_func_pipe2=no` for autotools deps (UTM does this).
- **Installed:**
  - cmake 4.2.3, pkg-config, python3 3.14, uv, gh 2.88.1 (authenticated as getBoolean), zstd, xz, bzip2, jq, libimobiledevice.
  - bison 3.8.2 and flex 2.6.4 are keg-only, so their paths must be set explicitly.
  - llvm@21 is keg-only (no lld in it). The swiftly toolchain provides lld.
- **Missing:**
  - Packaging: **ldid (ProcursusTeam), dpkg, xcodegen, reuse, git-lfs**, fakeroot (not needed if `--root-owner-group` is used).
  - Later cross-compiles: ninja, meson, autoconf/automake, llvm-mingw.
  - Theos: not installed.
- **Devices:**
  - One physical iPhone 13 mini (A15, iPhone14,4) on **iOS 27.0**, in Developer Mode. It can't run Dopamine 2 or TrollStore, so it can only test the AltStore/no-JIT path.
  - Dopamine and TrollStore device tests need other hardware on iOS 15–17.0.
  - Simulators are available.
- **Signing:** one Apple Development identity exists. It's not needed for any artifact.

## 2. `getBoolean/eikon-source` today (hosts apt files only)

- Public, default branch `main`. It holds `README.md` and `docs/{Packages, Release, depiction.json, index.html}`.
- **Pages is not enabled:** `GET /repos/.../pages` returns 404.
- **Broken or missing files:**
  - `Packages` points to `debs/com.getboolean.eikon_1.0.0_iphoneos-arm64.deb` and `icon.png`. Neither exists.
  - `Release` lists `Packages.bz2`/`.gz`, which don't exist.
  - **`Release` is malformed:** it has `MD5Sum`, `SHA1` and `SHA256` headers with no trailing colon. Sileo's parser skips those lines, so the hashes are never checked.
- **Text that has to change:**
  - The `Description` in `Packages` and `depiction.json` mentions demo sketch names and "Wine under FEX". Both are outdated.
  - `docs/index.html` says "not a live Sileo source".
  - All of it is rewritten when 01 publishes.

## 3. JIT

### 3.1 Dopamine 2 (iOS 15.0–16.6.1)
- **The mechanism is automatic, and the app calls nothing.**
  - From Dopamine **2.1**, launchd's jbserver handles `systemwide_process_checkin`. It is called from systemhook's constructor, before `main()`.
  - It sets `fullyDebugged` for any process whose resolved path starts with `JBROOT/Applications` (`/private/preboot/<hash>/dopamine-XXXXXX/procursus/Applications`) or `/private/var/containers/Bundle/Application`. The condition is jbsetting `markAppsAsDebugged` ("Allow JIT in Apps"), which is **on by default** and forced on during an update to 2.1.
  - `cs_allow_invalid(proc, true)` then clears `CS_KILL|CS_HARD`, sets `CS_DEBUGGED`, and on arm64e sets the pmap's `wx_allowed`.
  - **It does not need `get-task-allow`** (it is a kernel write).
- **No usable client API exists for apps:**
  - `jbclient_platform_set_process_debugged` is in the platform domain and requires `CS_PLATFORM_BINARY`.
  - `jbdswDebugMe` is Dopamine 1.x or roothide and **doesn't exist in 2.x**.
  - `jbctl proc_set_debugged <pid>` is for root or platform callers.
- **When a Dopamine deb has no JIT:**
  - Dopamine 2.0.x, which never sets `CS_DEBUGGED` for apps.
  - The "Allow JIT in Apps" toggle is off.
  - Tweak injection is disabled for the app through Choicy (no systemhook, no check-in).
  - Safe mode.
  - The app should then tell the user which setting to check.
- **Wrong heuristics to avoid:** Amethyst and LiveContainer infer JIT from "jailbroken" (systemhook loaded). Check `CS_DEBUGGED` instead.
- **Newer Dopamine:** 3.x (current 3.0.10) keeps the same logic, with the check-in moved to dyldhook. It now covers iOS 15–18.7.1 and some 26.0.x devices.
- Sources:
  - `opa334/Dopamine` 2.4.9: `BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c`, `libjailbreak/src/kernel.c`, `jbclient_xpc.h`
  - Release note 2.1

### 3.2 TrollStore 2.0.12+ (up to iOS 17.0)
- **`apple-magnifier://enable-jit?bundle-id=com.getboolean.eikon`:**
  1. `TSSceneDelegate` calls `openApplicationWithBundleID:`, which brings the app to the front.
  2. `trollstorehelper enable-jit` runs `ptrace(PT_ATTACHEXC)`, sleeps 100 ms, then `PT_DETACH` on the **running pid**.
  3. `CS_DEBUGGED` stays set after the detach.
- **No relaunch.** The same process gains JIT, so the "loop guard" is really "open the URL once, then poll with a timeout".
- **Needs `get-task-allow=true`** in the app's entitlements. TrollStore's own "Open with JIT" menu item appears only when the app is debuggable. On **iOS 16+, `get-task-allow` requires Developer Mode** to be on.
- **Other TrollStore setups:**
  - **Older TrollStore (1.3–2.0.11):** TrollStore opens, ignores the host, and the user is left in TrollStore. This needs a poll timeout and a clear message.
  - **URL scheme disabled in TrollStore settings:** the Magnifier or nothing opens. `openURL` completion may return NO.
- **Installer detection:**
  - TrollStore writes `_TrollStore` (Lite: `_TrollStoreLite`) into the bundle *container*, i.e. `bundleURL/../_TrollStore`.
  - A Dopamine deb's resolved bundle path contains `/procursus/Applications/`.
  - Fire the URL only when the `_TrollStore` marker exists and `CS_DEBUGGED` is missing.
- **Reference implementations:**
  - Amethyst: open once, poll `isJITEnabled` every 200 ms (no timeout).
  - LiveContainer: kill and relaunch, which is racy. Avoid it.
  - UTM doesn't use the URL at all. Its methods (self-ptrace, `dynamic-codesigning`) are ruled out for Eikon.

### 3.3 No-JIT build (AltStore) and JIT enablers
- AltSign signs with the **provisioning profile's** entitlements. Development profiles include `get-task-allow`, so StikDebug (iOS 17.4+, `stikjit://enable-jit?bundle-id=…&pid=…`), SideStore/SideJITServer, JitStreamer and AltJIT can attach and detach, which sets `CS_DEBUGGED`.
- The app only detects this, at launch and on each return to the foreground.
- It may offer a button that opens StikDebug's URL. That is another app doing the attach, which stays within the constraint.

### 3.4 Detection
- **Primary check:** `csops(getpid(), CS_OPS_STATUS, &flags, 4)`, then `flags & CS_DEBUGGED (0x10000000)`. `csops` is private; declare it `extern`.
  - On arm64 (A8–A11) Dopamine hooks `csops`, but it still reports the real value for the process itself.
- **Functional probe:**
  - Without JIT, `mmap`/`mprotect` to RX *succeed*, but executing the page gets **SIGKILL (uncatchable)**. So **run the probe only after `CS_DEBUGGED` is seen**. It confirms JIT, it doesn't discover it.
  - Steps:
    1. `mmap` an RX page.
    2. Make an RW alias with `vm_remap`.
    3. Write `mov w0,#42; ret` (`0x52800540, 0xd65f03c0`) through the alias.
    4. `sys_icache_invalidate`.
    5. Call it under `sigsetjmp` with SIGBUS, SIGSEGV, SIGILL and SIGTRAP handlers, and restore the handlers afterwards.
  - Fallback: toggle W^X with `mprotect`.
- **Write path:**
  - Don't use `MAP_JIT` or `pthread_jit_write_protect_np`. That API is unavailable on iOS in the SDK, and `MAP_JIT` needs `dynamic-codesigning`.
  - Assume RWX is not allowed on A12+ **[unverified]**. Always use split W^X, or dual mapping (the UTM split-wx, DolphiniOS and RetroArch pattern).
- **TXM:** enforcement changed only on **iOS 26+**, where `CS_DEBUGGED` alone is insufficient and regions must be "blessed" by a debugger that stays attached (StikDebug `universal.js`, `brk #0xf00d`).
  - It is irrelevant for Dopamine 2 and TrollStore ranges.
  - It *is* relevant to the AltStore build on current iOS, including the owner's iOS 27 iPhone 13 mini.
  - The device report should record whether TXM is present (preboot firmware file check, else a heuristic by chip and iOS).

## 4. Build system and UI

### Options
| Option | Verdict |
|---|---|
| Plain `.xcodeproj` + scripts (UTM, LiveContainer) | Works, but pbxproj merge noise and flavors are hand-kept |
| **XcodeGen `project.yml` + `.xcconfig` + Makefile → `scripts/*.sh`** | Recommended by research: deterministic, diffable, configurations map to flavors |
| Tuist | Too heavy for one app target |
| Theos rootless | Poor fit for SwiftUI, asset catalogs and large C++ deps. Doesn't produce ipa/tipa. Worth borrowing: `COPYFILE_DISABLE=1` |

### Patterns to copy
- **UTM:**
  - Build: `xcodebuild archive … -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`.
  - Frameworks: `lipo -thin` and fake-signing.
  - `package.sh` modes: `deb`, `ipa`, `ipa-hv` (TrollStore: no-sandbox, platform-application, AppDataContainers), `ipa-se` (no-JIT).
  - Signing order: frameworks first, then the main binary with `ldid -S<ent> -I<bundleid>`.
  - Zip with `-x "._*" .DS_Store __MACOSX`.
  - **UTM's deb installs an IPA through AppSync in `postinst`. Don't copy that.**
- **PojavLauncher v2.1.3:** stage `var/jb/Applications/App.app` directly, sign with `ldid -S App.app`, then `ldid -S<ents> App.app/App`, and package with `dpkg-deb -Zxz`. Use `Architecture: iphoneos-arm64`; Pojav has a bug here.
- **Cross-compiling C/C++ deps:**
  - UTM `build_dependencies.sh`: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"` with `-isysroot`.
  - Autotools: `--host=aarch64-apple-darwin`.
  - Meson: a cross file with `subsystem='ios'`.
  - CMake: `CMAKE_SYSTEM_NAME=iOS`, or leetal/ios-cmake.
  - Output goes to a per-platform sysroot.
  - Cache: `actions/cache` keyed on scripts, patches and submodule SHAs.
  - Wine's PE side will use llvm-mingw as a host toolchain.
- **UI:** UTM uses SwiftUI for the app, with UIKit view controllers for render and input surfaces bridged through `UIViewControllerRepresentable`. With an iOS 15 minimum there is no `NavigationStack` and no Observation, so use `NavigationView` and `ObservableObject`. The iOS 27 SDK's floor still allows iOS 15 **[verify in Xcode 27 notes]**.

## 5. Entitlements by install method

| Entitlement | Dopamine (ldid ad-hoc, trustcached) | TrollStore | AltStore |
|---|---|---|---|
| `com.apple.private.security.no-sandbox` | honored | honored. Keeps the data container when present | stripped |
| data container | uicache creates one unless `no-container` | TrollStore adds `container-required=<id>` unless no-sandbox/no-container | normal |
| `platform-application` | honored. Then needs IOKit user-client exceptions (AGX, IOSurface) | same | stripped |
| `…storage.AppDataContainers` | needed with no-sandbox + platform-application | same | stripped |
| `get-task-allow` | honored, not needed for JIT | **required for enable-jit**. Needs Developer Mode on iOS 16+ | always present (dev profile) |
| `com.apple.developer.kernel.increased-memory-limit` | kept **[kernel enforcement for ad-hoc unverified]** | kept | AltStore 2.2+ supports it. SideStore free drops it |
| `com.apple.developer.kernel.extended-virtual-addressing` | kept (same caveat) | kept | available to free dev tier. Whether AltStore requests it is **[unverified]** |
| `com.apple.private.memorystatus` | honored | honored | stripped |
| `dynamic-codesigning` | not used | **banned** (crash at launch on A12+ iOS 15+). Also banned: `com.apple.private.cs.debugger`, `com.apple.private.skip-library-validation` | stripped |
| `jb.pmap_cs.custom_trust` | Dopamine 2.1.5+ arm64e | n/a | n/a |

- **TrollStore re-signing:** TrollStore always re-signs with ldid and keeps your entitlements, except banned ones. If the main binary has no entitlements, it falls back to `TROLLTROLL`.
- **AltStore:** AltSign replaces your embedded entitlements with the profile's. It still reads them to decide which App ID capabilities to request, so they must still be embedded. It also rewrites the bundle ID for free accounts.

## 6. Signing and artifact formats

- **ldid:**
  - Install with `brew install ldid-procursus`. The `ldid` formula is saurik's 2.1.5, and the two conflict.
  - Order:
    1. Sign loose dylibs and executables with `ldid -S`.
    2. `ldid -S Eikon.app` (recursive, seals resources).
    3. `ldid -S<ent> -Icom.getboolean.eikon Eikon.app/Eikon`.
  - Verify with `ldid -e`.
  - Passing `-S<ent>` on the `.app` gives nested frameworks the same entitlements.
- **.tipa:** a normal IPA zip (`Payload/Eikon.app`) with a different extension, which TrollStore registers as its UTI.
- **Rootless deb:**
  - Layout: `stage/DEBIAN/control` plus `stage/var/jb/Applications/Eikon.app`.
  - Control fields: Package, Name, Version, `Architecture: iphoneos-arm64`, `Depends: firmware (>= 15.0)`, Section, Maintainer, Author, Installed-Size, Homepage, Icon, Depiction, SileoDepiction, `Tags: compatible_min::ios15.0`.
  - **No uicache needed in postinst:** Procursus `uikittools` has a dpkg trigger (`interest /var/jb/Applications`) that runs `uicache -a`. An optional `uicache -p` in postinst and `uicache -u` in prerm are belt-and-braces.
  - Build it with `COPYFILE_DISABLE=1 dpkg-deb --root-owner-group -Zxz -b stage out.deb`, using Homebrew dpkg 1.23. Set `SOURCE_DATE_EPOCH` for reproducibility and `chmod -R u=rwX,go=rX` the stage first.
- **Versioning:**
  - A `VERSION` file and a build number (`git rev-list --count HEAD`) generate `Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`).
  - The packagers read the version back from the built Info.plist and assert it equals `VERSION`.
  - On tag builds, CI asserts `tag == v$(VERSION)`.
  - Filenames: `Eikon-<v>.ipa`, `Eikon-<v>.tipa`, `com.getboolean.eikon_<v>_iphoneos-arm64.deb`.
- **Flavors (superseded: the owner chose one build, see claude-interview.md Q17):**
  - Configurations `Release-Main` and `Release-NoJIT`, via xcconfigs setting `SWIFT_ACTIVE_COMPILATION_CONDITIONS EIKON_NOJIT` and `GCC_PREPROCESSOR_DEFINITIONS EIKON_NOJIT=1`.
  - The deb and the tipa share the Main archive and differ only in entitlements and staging.

## 7. Sileo repo on GitHub Pages

- **What Sileo does with a flat repo URL** (verified in Sileo source):
  - It fetches `Release`, `Release.gpg`, and `Packages{.zst,.xz,.lzma,.bz2,.gz,}` (the first that succeeds).
  - `Release` **requires** `Architectures:` (containing `iphoneos-arm64`) and `Components:`.
  - It verifies **SHA256/SHA512** only, and every listed hash must match.
  - It filters stanzas by Architecture.
  - A relative `Filename` resolves against the repo URL. An absolute https `Filename` also works, in Sileo only.
  - The repo icon is `CydiaIcon.png` (and @2x/@3x) at the root.
  - **Unsigned repos are fine.** Don't publish `Release.gpg` without a keyring package.
- **Generating the index:**
  - `dpkg-scanpackages -m debs /dev/null > Packages`, then `xz` and `zstd`.
  - Write `Release` with a small shell function (`apt-ftparchive` isn't in Homebrew). Write to a temp file, then move it.
  - Put Name, Author, Icon, Depiction and SileoDepiction in the deb's control file, so `dpkg-scanpackages` copies them into the index.
- **Native depiction:** `DepictionTabView` with `minVersion` 0.4 and `tintColor`. Omit an empty `headerImage`. A "Licenses" tab can reuse the credits data.
- **Pages:**
  - Deploy from branch `main` `/docs` with `docs/.nojekyll`. It is the simplest option, and Sileo's own repo uses the same model.
  - Share the URL with a trailing slash.
  - **Limits:** git blocks files over 100 MiB, a site can be at most 1 GB, and Pages serves LFS *pointers*, not files.
  - A deb over about 100 MB must be hosted as a GitHub Release asset on `eikon`, with an absolute `Filename` (Sileo only).
  - Keep only the latest deb, or latest plus previous. Version history belongs in GitHub Releases on `eikon`.
- **Cross-repo publishing:**
  - `GITHUB_TOKEN` can't push to another repo.
  - Use an SSH **deploy key** with write access to `eikon-source` only, stored as a secret in `eikon`. The alternatives are a fine-grained PAT or a GitHub App token.
  - Put the index-generation script in `eikon-source` (`scripts/update-repo.sh`) so CI and local publishing share it. The local flow is: clone, copy the deb, run the script, commit, push.

## 8. Credits and license check

- **REUSE (`reuse lint`)** ignores submodules. Use it for Eikon's own files at most.
- **licensee** detects the top-level license. It is useful as a cross-check.
- **ScanCode** is deep but slow. Run it by hand when submodule pins change, to find nested licenses.
- **LicensePlist** can consume `manual:` entries, but a custom generator is simpler.
- **Recommended pipeline:**
  - A manifest `third_party/credits.yaml`, one entry per component: name, path (equal to a `.gitmodules` path), url, SPDX license, license_files, and nested sub-licenses.
  - A check script that fails when:
    - a submodule or vendored directory has no entry
    - an entry is stale
    - a license file is missing
    - an SPDX expression is invalid
  - Generators produce `THIRD_PARTY_NOTICES`, a `licenses/` directory, and an in-app acknowledgements JSON in the bundle (02 renders it). The notices file is also copied into the deb under `/var/jb/usr/share/doc/com.getboolean.eikon/`, and optionally into a depiction tab.
  - GPL/LGPL source offer: point to the `eikon` tag and the pinned submodule commits.

## 9. Testing context (new project)

There is no existing test setup. What research suggests is available:

- **Swift and ObjC unit tests:** XCTest (or Swift Testing, with Swift 6.4) in an app-hosted or logic test target, run on the **iOS Simulator** with `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 16e'`.
  - On the simulator, `csops` reports no `CS_DEBUGGED`.
  - JIT-positive paths are therefore tested by injecting the csops result and the probe through a protocol, plus the real probe on a macOS host where possible **[the simulator may allow RX alias execution; verify]**.
- **Script tests:** use bats-core or plain shell/Python tests (pytest via uv) to check:
  - the credits checker (fixture repos with and without entries)
  - the Release/Packages generation (hashes, colons, fields)
  - version consistency
  - artifact layout (unzip or `dpkg-deb -c` the artifacts, check paths, `ldid -e` entitlements per artifact, and that `dynamic-codesigning` and banned keys are absent)
- **Device checks:** manual, recorded through the device-report format. Records device, iOS, chip, install method, build, JIT state and source, and TXM.

## Testing Approach (decided)

This is a new project, and the owner decided the approach in interview Q12 and Q13.

**Swift Testing.**
- Runs in the `EikonKitTests` target through `xcodebuild test -scheme Eikon` on an iPhone simulator.
- Device and filesystem facts are injected through the `JITSystem` and `BundleEnvironment` seams, a test `UserDefaults` suite, and a controllable clock.

**pytest.**
- Run with `uv run pytest tests/` on Python 3.12, pinned by `.python-version`.
- Scripts use only the standard library.
- Fixtures build throwaway git repositories under `tmp_path`.

**Rule: few tests, behavioral only.**
- Tests cover features and prevent bugs.
- They don't pin implementation details, exact file contents or constant values.
- Artifact correctness is enforced by the verifier script in CI, not by unit tests.
- Device behaviour is proven by filed device reports.
