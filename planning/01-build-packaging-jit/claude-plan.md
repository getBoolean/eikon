# Implementation plan: 01 · Build, packaging, and JIT enablement

## 1. Context

Eikon is an iPhone and iPad app that will run Windows and Linux x86 games (through FEX-Emu, Wine and Box64) and Kirikiri and Ren'Py games natively. The app repository `github.com/getBoolean/eikon` is public and holds only planning documents today. There is no source, no build system, no submodules and no license file.

This split creates the project. When it is done:

1. **Build.** One command (`make all`) or one CI job builds **one app binary** at one version.
2. **Packages.** It packages that binary three ways:
   - a Dopamine rootless deb (package id `com.getboolean.eikon`, `iphoneos-arm64`, installed at `/var/jb/Applications/Eikon.app`)
   - `Eikon.tipa` for TrollStore
   - `Eikon.ipa` for AltStore
3. **JIT.** The app turns JIT on automatically where the install method allows it. It reports whether the process has **usable** JIT and where it came from. When JIT is not usable, it reports a reason code and how to fix it.
4. **Device report.** The app exports a JSON device report, and a script files it into the repo.
5. **Credits.** A credits pipeline (manifest, check, generators) guards every third-party component later splits add.
6. **Publishing.** The deb is published to the Sileo repo `https://getboolean.github.io/eikon-source/`, served by GitHub Pages from the separate repo `getBoolean/eikon-source`.

No game features and no guest code are in scope. A later split (02) builds the game library and renders the credits screen from data produced here.

### 1.1 Decisions this plan rests on

| Topic | Decision | Why |
|---|---|---|
| Build model | **One build.** Artifacts differ only in entitlements, one Info.plist stamp, and container format. Routes are chosen at run time. | An install without JIT still runs the no-JIT routes, and an AltStore install that gets JIT from an enabler can use FEX. There is one archive to build and test. |
| Build system | **XcodeGen** (`project.yml`) + `.xcconfig` + a **Makefile** calling scripts. The generated `.xcodeproj` is not committed. | Deterministic and easy to diff. Theos fits SwiftUI and large C++ dependencies poorly, and a committed pbxproj causes merge noise. |
| UI | **SwiftUI**. UIKit view controllers will host render and input surfaces later. | UTM's split. The iOS 15 minimum means `NavigationView` and `ObservableObject`: no `NavigationStack`, no Observation, no `Mutex`, no `OSAllocatedUnfairLock`. |
| Minimum OS | iOS 15.0 everywhere. **Verified:** the iOS 27 SDK's `MinimumDeploymentTarget` is 15.0. | Dopamine 2 floor. |
| Scripts | Python 3.12 through **`uv run`** (pinned by `.python-version`), standard library only. pytest is the only dev dependency. No Python runs inside Xcode build phases. | The system `/usr/bin/python3` is 3.9.6 and lacks `tomllib`. Xcode's script sandboxing complicates build-phase scripts. |
| Signing | ProcursusTeam **ldid** (Homebrew `ldid-procursus`, not `ldid`), with one bundle-level signing call. | Homebrew's `ldid` is saurik's version. A bundle-level call seals resources correctly. |
| JIT write path | An RW allocation, a `vm_remap` alias (`copy=FALSE`), and the execute view `mprotect`ed to RX. Never `MAP_JIT`, never `dynamic-codesigning`. | `dynamic-codesigning` crashes on iOS 15+ A12+ and TrollStore bans it. Simultaneous RWX is assumed forbidden on A12+. This is the sequence UTM and Dolphin use. |
| `platform-application` | Not used. | Stricter IOKit sandbox (Metal would need GPU exceptions), can cost the data container, and nothing needs it. |
| Deb hosting | Debs are **GitHub Release assets on `eikon`**. `eikon-source` holds only the index and Pages files. `Packages` uses an absolute `Filename`. | Debs will exceed GitHub's 100 MB git limit once FEX and Wine land, and Pages can't serve LFS. Absolute `Filename` works in Sileo; plain apt is not a target. |
| Release policy | **CI is the canonical publisher.** Release assets are never replaced: a fix means a new version. | Re-uploaded assets change hashes and break Sileo's cached index. |
| Pages | Branch `main`, folder `/docs`, `.nojekyll`. No workflow file. | Simplest. It needs no workflow-write permission (an earlier attempt failed on that), and it keeps `eikon-source` to package files. |
| Tests | Swift Testing for core logic on the simulator, and pytest for scripts. **Few tests, behavioral only.** | The owner's standing rule: tests cover features and prevent bugs, and don't pin implementation details, file contents or constants. |
| First version | `0.1.0` | It replaces a phantom `1.0.0` index entry whose deb was never uploaded. |

### 1.2 Constraints

- **No exploit and no JIT bypass of Eikon's own.** Eikon never attaches a debugger or calls `ptrace` or task-for-pid. It relies on:
  - Dopamine's automatic JIT
  - TrollStore's enable-jit URL (TrollStore does the attaching)
  - on AltStore, detection only of JIT an external enabler provided
- **Forbidden in every artifact:** `dynamic-codesigning`, `com.apple.private.cs.debugger`, `com.apple.private.skip-library-validation`, `com.apple.private.persona-mgmt`, `platform-application`.
- **No program titles anywhere.** That covers code, depictions, device reports, test names and commit messages. `/Volumes/Games` is not used by this split.
- **Supported ranges:**

  | Install method | iOS range |
  |---|---|
  | Dopamine 2 | 15.0–16.6.1 |
  | TrollStore | up to 17.0 |
  | AltStore | current iOS |

- **Test hardware:**
  - **iPad Pro 12.9" 6th gen (M2), iPadOS 17.0:** TrollStore, and Dopamine 3 if it supports that device. Dopamine 3 grants JIT the same way as 2.1+.
  - **iPhone 13 mini (A15), iOS 27.0:** AltStore. This device has Apple's Trusted Execution Monitor (TXM).
  - Dopamine 2 itself is desktop-verified only.
- **Development Mac:**
  - macOS 27, Xcode 27.0 (iOS SDK 27.0), Swift 6.4, system Python 3.9.6.
  - `~/.swiftly/bin` precedes `/usr/bin` on PATH, so scripts invoke compilers through `xcrun`.
  - Missing today: xcodegen, ldid-procursus, dpkg.

---

## 2. Background the implementer needs

### 2.1 How each install method provides JIT

"JIT" means the process may execute pages it wrote itself. On iOS this holds when the kernel has set `CS_DEBUGGED` (`0x10000000`) in the process's code-signing flags. The flags are read with the private libsystem call `csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags)`.

**Dopamine 2.1+ (and 3.x)**
- Every process gets the jailbreak's `systemhook.dylib`, whose constructor "checks in" with launchd's jbserver.
- For executables under the jailbreak root's `Applications` directory, jbserver sets `CS_DEBUGGED` in the kernel **before `main()`**, when the Dopamine setting "Allow JIT in Apps" is on (the default).
  - The resolved path looks like `/private/preboot/<hash>/dopamine-XXXXXX/procursus/Applications/…`.
  - Dopamine does the same for apps under `/private/var/containers/Bundle/Application`, so a `.tipa` or `.ipa` installed on a Dopamine device may start with JIT.
- No entitlement and no API call are needed. Dopamine 2.x has no public "debug me" client call (`jbdswDebugMe` was Dopamine 1.x).
- JIT is absent when:
  - the toggle is off
  - tweak injection is disabled for the app through Choicy
  - the device is in safe mode
  - the jailbreak is Dopamine 2.0.x, which never marked apps
- Other rootless jailbreaks (palera1n, nathanlr) also use `/var/jb`, so `/var/jb` alone does not identify Dopamine. Dopamine leaves `/var/jb/.installed_dopamine` and a `basebin` directory under its root.

**TrollStore 2.0.12+**
- Opening `apple-magnifier://enable-jit?bundle-id=<bundle id>` switches to TrollStore.
- TrollStore brings the app back to the foreground. Its root helper then attaches to the **running** process with `ptrace(PT_ATTACHEXC)`, waits about 100 ms, and detaches. `CS_DEBUGGED` stays set.
- The app is **not relaunched**. The failure to guard against is bouncing to TrollStore repeatedly.
- Requires `get-task-allow` in the app's entitlements. On iOS 16+, apps with `get-task-allow` need Developer Mode on. TrollStore users don't all have it on, so this is documented as a `.tipa` requirement.
- On TrollStore older than 2.0.12, or with TrollStore's URL scheme disabled, nothing happens. The app therefore waits with a deadline.
- TrollStore writes a `_TrollStore` marker (TrollStore Lite: `_TrollStoreLite`) into the bundle container, i.e. `Bundle.main.bundleURL/../_TrollStore`.

**AltStore**
- AltStore re-signs with the developer profile's entitlements, which include `get-task-allow`.
- Free accounts may also rewrite the bundle id, so the app must never assume the literal `com.getboolean.eikon` at run time.
- An external enabler (StikDebug, SideJITServer, and so on) can attach and detach, which sets `CS_DEBUGGED`. Eikon only detects this.

**TXM (iOS 26 and later, on chips that have it)**
- `CS_DEBUGGED` alone is not enough there. Every executable JIT region must be approved by a debugger that stays attached.
- Eikon reports JIT as not usable (reason `txmEnforced`) and must not execute JIT code, because an unapproved execution kills the process.
- The approval protocol is left to later splits (05, 14).

### 2.2 Why the functional probe is gated

Without JIT, mapping a page RX *succeeds*, but executing it makes the kernel send **SIGKILL**, which can't be caught. So the probe that runs generated code is only a confirmation:
- It runs only when `CS_DEBUGGED` is set, TXM doesn't block it, and a crash sentinel doesn't forbid it.
- It is never used to discover JIT.

### 2.3 Why `usable`, not just "has JIT"

Later splits pick routes from one question: can this process run generated code now?

- The answer is `usable = csDebugged && probe passed`.
- It can change from false to true during the process lifetime, for example when TrollStore or an enabler attaches.
- Usable means FEX runs Windows and Linux games.
- Not usable means native engines run, and later Box64's interpreter runs 32-bit Windows games.

---

## 3. Repository layout after this split

```
eikon/
  VERSION                         # "0.1.0"; single source of the marketing version
  LICENSE                         # GPL-3.0 full text (project is GPL-3.0-or-later)
  THIRD_PARTY_NOTICES.md          # generated from third_party/credits.toml, committed
  licenses/                       # license texts named <SPDX-id>.txt (GPL-3.0-or-later.txt now)
  README.md                       # build instructions, install methods, JIT behaviour, requirements
  Makefile                        # entry point for every task
  project.yml                     # XcodeGen spec
  .python-version                 # 3.12, used by uv
  pyproject.toml                  # uv project: pytest only
  Config/
    Base.xcconfig                 # shared settings; #include? "../build/generated/Version.xcconfig"
    Debug.xcconfig
    Release.xcconfig
  App/
    EikonApp.swift                # @main App; observes JITController.shared; scene phase
    StatusView.swift              # the one screen
    ReportExport.swift            # copy/share helpers (UIActivityViewController bridge)
    Localizable.strings           # English strings, including reason-code texts
    Info.plist
    Assets.xcassets/              # original app icon
    Resources/Acknowledgements.json  # checked-in empty placeholder ([]); build copies the generated one
  Packages/EikonKit/              # local Swift package, testable core
    Package.swift
    Sources/CEikonJIT/            # C: csops wrapper, probe, TXM firmware check
      include/CEikonJIT.h
    Sources/EikonKit/             # Swift: install method, JIT policy/controller/store, device info, report
    Tests/EikonKitTests/          # Swift Testing
  third_party/
    credits.toml                  # credits manifest (no components in 01)
    README.md                     # the submodule/patch convention
  patches/                        # patches/<component>/NNNN-*.patch (empty in 01)
  packaging/
    entitlements/{deb,tipa,ipa}.plist, README.md
    deb/{control.in,postinst,prerm}
    repo/{depiction.json.in,index.html.in,README.md.in,icon/}
  scripts/
    doctor.sh  bootstrap.sh  version.sh  archive.sh  package.sh
    apply_patches.py  credits.py  verify_artifacts.py  file_device_report.py
    repo/build_index.py  repo/publish.sh
  device-reports/
    schema.json
    README.md                     # runbook + how to file
  tests/                          # pytest suite for scripts
  .github/workflows/{ci.yml,release.yml}
  .gitignore                      # build/, dist/, *.xcodeproj, DerivedData, .venv
```

---

## 4. Tooling and Makefile

### 4.1 Tools
- **`scripts/doctor.sh`** checks for:
  - Xcode and an iphoneos SDK
  - `xcodegen`
  - `ldid` of the Procursus variant (its version output names Procursus, or it accepts `-M`)
  - `dpkg-deb`, `uv`, `gh`, `zstd`, `xz`

  It prints what is missing and exits non-zero if anything is.
- **`scripts/bootstrap.sh`** runs `brew install xcodegen ldid-procursus dpkg uv` for the missing tools. It warns if the conflicting `ldid` formula is installed. It runs only when the owner asks. Other targets never call it.

### 4.2 Makefile targets

| Target | Does |
|---|---|
| `doctor` / `bootstrap` | the scripts above |
| `version` | writes `build/generated/Version.xcconfig` |
| `generated` | `version`, then `uv run scripts/credits.py app-json build/generated/Acknowledgements.json` |
| `project` | `generated`, then `xcodegen generate` |
| `check` | `uv run scripts/credits.py check` and `scripts/version.sh --check` |
| `test` | `test-swift` + `test-scripts` |
| `test-swift` | `xcodebuild test -scheme Eikon` on the newest available iPhone simulator (chosen by the script) |
| `test-scripts` | `uv run pytest tests/` |
| `archive` | `project`, then `scripts/archive.sh` → `build/Eikon.xcarchive` |
| `ipa` / `tipa` / `deb` | `scripts/package.sh <kind>` → `dist/` |
| `package` | all three, plus `dist/SHA256SUMS` |
| `verify` | `uv run scripts/verify_artifacts.py dist/` |
| `all` | `check test archive package verify` |
| `publish` | `scripts/repo/publish.sh` (see 12.4) |
| `apply-patches` / `unpatch` | section 5 |
| `clean` | removes `build/` and `dist/` |

**Acknowledgements JSON wiring:** the app target lists `build/generated/Acknowledgements.json` as a resource when it exists, and `App/Resources/Acknowledgements.json` otherwise. XcodeGen chooses the path at generation time. A Release build without the generated file is an error, enforced in `archive.sh`.

---

## 5. Third-party convention, patches and version

### 5.1 Submodule convention (`third_party/README.md`)
- **Location and pinning.** Every upstream is a git submodule at `third_party/<name>`, pinned to a tag or commit. `.gitmodules` sets `ignore = dirty`.
- **Patches.** Changes live only as `patches/<name>/NNNN-short-description.patch`. Create them with `git format-patch` against the pinned revision. They apply in lexical order **with `git apply` (working tree only)**, so the submodule's HEAD never moves and the superproject never records a patched commit.
- **Out-of-tree builds.** Upstream builds must build **out of tree** (under `build/`), because resetting a submodule cleans its working tree.
- **Credits in the same commit.** The commit that adds a submodule must add its credits entry and license texts (section 6), and CI enforces this.
- **Notes for later splits:**
  - Cross-compile flags: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"` with `-isysroot`.
  - Per build system: CMake `CMAKE_SYSTEM_NAME=iOS`; autotools `--host=aarch64-apple-darwin`; meson cross file with `subsystem='ios'`.
  - `ac_cv_func_pipe2=no` for the iOS 27 SDK.
  - Keg-only Homebrew `bison` and `flex` must be on PATH explicitly.
  - llvm-mingw is the host toolchain for Wine's PE side.
  - Dynamic libraries go in `Frameworks/<name>.framework` with `@rpath` install names.
  - CI caches are keyed on dependency scripts, `patches/**` and submodule SHAs.

### 5.2 `scripts/apply_patches.py`

```python
def apply_all(repo_root: Path, components: list[str] | None = None) -> None:
    """For each submodule (or the named ones): read the pinned commit from the superproject's
    gitlink (`git ls-tree HEAD <path>`), make sure the submodule is initialised and checked
    out at exactly that commit with a clean working tree, then for each patches/<name>/*.patch
    in lexical order run `git apply --check` and then `git apply`. Running it twice yields the
    same tree. A patch that fails --check aborts with the component and patch name, and the
    submodule is left reset to its pin."""

def restore_all(repo_root: Path, components: list[str] | None = None) -> None:
    """Reset submodules to their pinned commits with clean working trees (make unpatch)."""
```

- Submodules with no patch directory are just reset.
- It is invoked as `uv run scripts/apply_patches.py [apply|restore] [names…]`.

### 5.3 `scripts/version.sh`

**What it writes.** It produces `build/generated/Version.xcconfig` with three settings:

| Setting | Source |
|---|---|
| `MARKETING_VERSION` | `VERSION` |
| `CURRENT_PROJECT_VERSION` | `git rev-list --count HEAD`, or the `EIKON_BUILD_NUMBER` override |
| `EIKON_GIT_COMMIT` | the short SHA, plus `-dirty` if the tree is dirty |

**Failure rules.**
- It **fails on a shallow clone** (`git rev-parse --is-shallow-repository`) unless `EIKON_BUILD_NUMBER` is set, because the commit count would be wrong. CI checks out with `fetch-depth: 0`.
- `VERSION` must match `^\d+\.\d+\.\d+$`, since `CFBundleShortVersionString` must be numeric.

**Modes.**
- `--check` validates the `VERSION` format. If `HEAD` has a `v*` tag, it also requires that tag to equal `v$(VERSION)`.
- `--check-tag <tag>`, used by the release workflow, requires `tag == v$(VERSION)`.

**Opening in Xcode first.** `Config/Base.xcconfig` includes the generated file optionally and provides fallbacks, so the project opens in Xcode before `make version` has run.

---

## 6. Licensing and credits pipeline

### 6.1 Files
- `LICENSE` holds the GPL-3.0 text. The README states "GPL-3.0-or-later".
- `licenses/<SPDX-id>.txt` holds one text per license id in use. `GPL-3.0-or-later.txt` is there from the start.
- `THIRD_PARTY_NOTICES.md` is generated and committed.

### 6.2 Manifest `third_party/credits.toml`

```
[[component]]
name            # display name
path            # repo-relative, e.g. "third_party/FEX"; must equal a .gitmodules path or a vendored dir
url             # upstream URL
revision        # pinned tag/commit (informational; notices use the actual gitlink commit)
license         # SPDX expression, e.g. "MIT" or "LGPL-2.1-or-later"
license_files   # paths relative to `path`, e.g. ["LICENSE"]
[[component.nested]]   # optional sub-licensed parts that ship
path, license, license_files
```

There are no components in 01.

### 6.3 `scripts/credits.py`

```python
def check(repo_root: Path) -> list[str]:
    """Return problems (empty = pass). Reports:
    - a submodule path in .gitmodules, or a directory directly under third_party/, with no entry;
    - an entry whose path is absolute, contains '..', or does not exist;
    - a listed license file (top-level or nested) that does not exist;
    - an SPDX id used in any expression with no licenses/<id>.txt;
    - THIRD_PARTY_NOTICES.md differing from generate_notices() output."""

def generate_notices(repo_root: Path) -> str:
    """Markdown: Eikon itself, then each component: name, URL, pinned commit (from the gitlink),
    SPDX expression, full license text(s) including nested parts. States where corresponding
    source is published for GPL/LGPL parts: the eikon release tag and the pinned submodule commits."""

def generate_app_json(repo_root: Path, out: Path) -> None:
    """Acknowledgements JSON for the app: list of {name, url, revision, license, licenseText}.
    Split 02 renders it."""
```

- CLI: `check`, `notices [--write]`, `app-json <out>`.
- SPDX ids are extracted by splitting expressions on `AND`, `OR`, `WITH` and parentheses. The full SPDX grammar isn't needed.

---

## 7. Xcode project and app lifecycle

### 7.1 `project.yml`

**Project.** Named `Eikon`. Settings come from `Config/*.xcconfig`: iOS 15.0, `arm64` only, Swift language mode 6 with complete strict concurrency.

**Local package.** `Packages/EikonKit`, with library product `EikonKit` and test target `EikonKitTests`.

**Target `Eikon` (application).**
- Sources: `App/`. Depends on `EikonKit`.
- Identity: bundle id `com.getboolean.eikon`, display name "Eikon".
- Info.plist:
  - `CFBundleShortVersionString = $(MARKETING_VERSION)`
  - `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
  - `EKGitCommit = $(EIKON_GIT_COMMIT)`
  - `EKPackageKind = development`; the packager overwrites it with `deb`, `tipa` or `ipa`
  - `UILaunchScreen = {}`, which prevents letterboxing and enables iPad multitasking
  - all orientations supported
- The acknowledgements resource, as in 4.2.
- No build-phase scripts.

**Scheme `Eikon`.** Its test action includes `testTargets: [package: EikonKit/EikonKitTests]`.

**Signing.**
- Archive builds use `CODE_SIGNING_ALLOWED=NO`.
- Simulator and debug device runs may use the owner's Apple Development identity.
- The README explains the debug loop (7.3).

**Privacy manifest.** `PrivacyInfo.xcprivacy` is intentionally omitted: it matters only for App Store distribution, which none of the install methods use.

### 7.2 Ownership and launch sequence
- **One instance.** `JITController.shared` is created lazily on first access. `EikonApp` holds it with `@ObservedObject`, and nothing else constructs one.
- **At `EikonApp.init`:** access `JITController.shared` and call `gatherFacts()`. This reads `CS_DEBUGGED`, TXM and the install method, and records when `CS_DEBUGGED` was seen (`atLaunch`). It then runs the probe if the policy allows. No UI or URL calls happen here.
- **On every `scenePhase == .active`:** call `JITController.shared.sceneBecameActive()`.
  - The **first** activation may start the TrollStore request (9.3).
  - Later activations re-check `CS_DEBUGGED`, marked as `onForeground`, for AltStore enablers and TrollStore's return.

### 7.3 Debug loop (README)

An Xcode-debugged run on the iPad sets `CS_DEBUGGED`, which exercises the real probe without TrollStore. The debugger stops on the probe's guarded signals. Use `process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false` in lldb, or a `.lldbinit` snippet, to let the guard handle them.

---

## 8. Install-method detection (`EikonKit`)

```swift
enum InstallMethod: String, Codable, Sendable {
    case dopamine, rootlessJailbreak, trollStore, trollStoreLite, sideloaded, simulator, unknown
}

struct InstallEvidence: Codable, Sendable {
    var bundlePath: String          // resolved, redacted to structure (see below)
    var homeDirectory: String       // NSHomeDirectory(), redacted — shows where no-sandbox data lands
    var markers: [String]           // e.g. ["_TrollStore"], [".installed_dopamine"], ["embedded.mobileprovision"]
}

protocol BundleEnvironment: Sendable {
    /// Filesystem seam so detection is testable against a fake layout.
    var bundleURL: URL { get }
    var homeDirectory: URL { get }
    var isSimulator: Bool { get }
    func fileExists(_ path: String) -> Bool
    func resolvingSymlinks(_ url: URL) -> URL
}

func detectInstallMethod(_ env: BundleEnvironment) -> (InstallMethod, InstallEvidence)
```

**Detection rules, first match wins:**

1. A simulator build → `simulator`.
2. `bundleURL/../_TrollStore` exists → `trollStore`. `_TrollStoreLite` exists → `trollStoreLite`.
3. The resolved bundle path is under a jailbreak `Applications` directory (it contains `/procursus/Applications/` or starts with `/var/jb/Applications/`):
   - `dopamine` if a Dopamine marker exists (`/var/jb/.installed_dopamine`, or `basebin` under the jailbreak root)
   - otherwise `rootlessJailbreak`
4. `bundleURL/embedded.mobileprovision` exists → `sideloaded`.
5. Otherwise → `unknown`.

**Redaction.** Replace preboot hashes, `dopamine-XXXXXX` suffixes and container UUIDs with placeholders (`<hash>`, `<id>`, `<uuid>`), keeping only structure. Reports then carry no device-unique identifiers.

**Package kind.** Read from Info.plist `EKPackageKind`. The report shows both it and the detected method. A mismatch is informative, not an error.

**Bundle id.** Always taken at run time from `Bundle.main.bundleIdentifier`.

---

## 9. JIT status, probe, store and controller

### 9.1 C layer (`Sources/CEikonJIT`)

```c
/* 0 and *flags from csops(getpid(), CS_OPS_STATUS, …); errno otherwise. */
int eikon_cs_flags(uint32_t *flags);

typedef enum {
  EIKON_PROBE_PASSED = 0,
  EIKON_PROBE_ALLOC_FAILED,       /* RW allocation failed */
  EIKON_PROBE_REMAP_FAILED,       /* vm_remap alias failed */
  EIKON_PROBE_PROTECT_FAILED,     /* mprotect(RX) on the execute view failed */
  EIKON_PROBE_PROTECTION_MISMATCH,/* remap cur/max protections cannot give RX + RW */
  EIKON_PROBE_WRONG_RESULT,       /* code ran but did not return 42 */
  EIKON_PROBE_SIGNAL              /* guarded signal while executing */
} eikon_probe_status;

typedef struct { eikon_probe_status status; int signal; int error; } eikon_probe_result;

/* Proven dual-mapping sequence: allocate one page RW (vm_allocate / mmap, no MAP_JIT);
 * vm_remap it (copy = FALSE) to get a second view; check the returned cur/max protections;
 * mprotect the execute view to RX, keep the other RW; write `mov w0,#42 ; ret` through the RW
 * view; sys_icache_invalidate the RX view; call it under a sigsetjmp guard.
 * Signal handling: SIGBUS/SIGSEGV/SIGILL/SIGTRAP handlers installed with sigaction(SA_SIGINFO);
 * a handler longjmps only if it runs on the probe thread AND si_addr / pc lies in the probe
 * page; otherwise it chains to the previously installed handler (or restores SIG_DFL and
 * re-raises). Previous handlers are always restored; calls are serialised by a mutex; both
 * views are unmapped before returning. Page size from getpagesize().
 * MUST only be called when JITPolicy.mayProbe is true. */
eikon_probe_result eikon_jit_probe(void);

/* 1 present, 0 absent, -1 undeterminable: looks for Ap,TrustedExecutionMonitor.img4 under
 * /private/preboot/<hash>/usr/standalone/firmware/FUD/. Sandboxed installs get -1. */
int eikon_txm_firmware_present(void);
```

`csops` is declared `extern` in the C file. It is private libsystem API and needs no entitlement.

### 9.2 Pure policy (`JITPolicy.swift`)

```swift
enum TXMState: String, Codable, Sendable { case present, absent, unknown }

enum CSDebuggedSeen: String, Codable, Sendable { case never, atLaunch, afterTrollStoreRequest, onForeground }

enum JITSource: String, Codable, Sendable {
    case none, dopamine, rootlessJailbreak, trollStore, externalEnabler, preexisting, unknown
}

enum JITReasonCode: String, Codable, Sendable, CaseIterable {
    case dopamineJITOff              // toggle off, Choicy, safe mode, or Dopamine 2.0
    case rootlessJailbreakNoJIT      // non-Dopamine /var/jb jailbreak without JIT
    case trollStoreRequestPending
    case trollStoreTimedOut          // TrollStore < 2.0.12, or its URL scheme disabled; Retry offered
    case sideloadedNoJIT             // optional; says what runs without it
    case txmEnforced                 // JIT from a debugger is not usable on this device yet
    case txmUndetermined             // iOS 26+ and TXM could not be ruled out
    case probeSkippedAfterCrash      // the previous launch died during the probe; Retry probe offered
    case probeFailed                 // unexpected; detail in probe outcome
    case unknownInstallNoJIT
    case simulator
}

struct ProbeOutcome: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case notRun, passed, failed }
    var kind: Kind
    var detail: String?              // why not run, or which step failed / which signal
}

struct TXMInfo: Codable, Sendable, Equatable {
    var state: TXMState
    var enforced: Bool               // true only on iOS 26+ with state == .present (or treated so)
    var basis: String                // "firmware", "cpufamily heuristic", "os below 26"
}

struct JITStatus: Codable, Sendable, Equatable {
    var csDebugged: Bool
    var csDebuggedSeen: CSDebuggedSeen
    var txm: TXMInfo
    var probe: ProbeOutcome
    var source: JITSource
    var reason: JITReasonCode?       // nil exactly when usable
    var usable: Bool { csDebugged && probe.kind == .passed }   // computed; also encoded
}

struct JITFacts: Sendable {
    var installMethod: InstallMethod
    var csDebugged: Bool
    var csDebuggedSeen: CSDebuggedSeen
    var txm: TXMInfo
    var trollStoreRequest: TrollStoreRequestState   // none / pending / timedOut
    var probeBlockedBySentinel: Bool
}

enum JITPolicy {
    /// True only with CS_DEBUGGED, TXM not enforced (and not undetermined on iOS 26+),
    /// not a simulator, and no crash sentinel from this build.
    static func mayProbe(_ facts: JITFacts) -> Bool

    /// Facts + probe outcome → status: source attribution and reason code.
    static func status(_ facts: JITFacts, probe: ProbeOutcome) -> JITStatus

    /// Automatic: trollStore/trollStoreLite, no CS_DEBUGGED, not tried this process, and
    /// lastAttempt outside the cooldown. Manual (Retry): only the install method and flag matter.
    static func shouldRequestTrollStoreJIT(installMethod: InstallMethod, csDebugged: Bool,
                                           triedThisProcess: Bool, lastAttempt: Date?,
                                           now: Date, manual: Bool) -> Bool
}
```

**Source attribution, when `CS_DEBUGGED` is set:**

| Install | When seen | Source |
|---|---|---|
| dopamine | any | `dopamine` |
| rootlessJailbreak | any | `rootlessJailbreak` |
| trollStore / Lite | `afterTrollStoreRequest` | `trollStore` |
| trollStore / Lite | `atLaunch` | `preexisting`, e.g. "Open with JIT" from TrollStore's menu, or a Dopamine device marking container apps |
| sideloaded | `onForeground` | `externalEnabler` |
| sideloaded | `atLaunch` | `preexisting` |
| unknown | any | `unknown` |

Without `CS_DEBUGGED`, the source is `none`.

**Reasons.** Every non-usable status carries exactly one reason code.
- The UI maps codes to localised text in `Localizable.strings`. The texts give the cause and fix per section 2.1.
- The `sideloadedNoJIT` text says what runs without JIT, and doesn't link or name any enabler in UI actions (owner decision).
- The `txmEnforced` text says an enabler won't make JIT usable on this device yet, and that native routes still work.
- `.tipa` Developer Mode is not a timeout reason: without Developer Mode the app may not launch at all. It is documented in the README and depiction instead.

**TXM (`TXMInfo`).**
- Prefer the firmware check when it returns 0 or 1.
- Otherwise:
  - iOS below 26 → `absent`, `enforced=false`, basis "os below 26".
  - iOS 26+ → a heuristic keyed on **`hw.cpufamily`** (chip generation), from a Swift literal table giving, per CPU family, the first iOS major version where TXM is enforced. Families not in the table → `unknown`, treated as enforced (conservative).
- Reports on iOS below 26 may show `present` with `enforced=false`.

**Persistence.**
- **Cooldown.** The time of the last automatic TrollStore attempt is kept in `UserDefaults`, followed by `synchronize()`. The cooldown is a named constant of about one minute.
- **Crash sentinel.** Before calling `eikon_jit_probe`, write the file `Library/Caches/eikon-probe-sentinel` with `open(O_CREAT|O_TRUNC)`, then `write` the current build number, then `fsync`. Delete it after the probe returns.
  - At launch, a sentinel holding **this** build number sets `probeBlockedBySentinel` (reason `probeSkippedAfterCrash`) and is then deleted, so exactly one launch is skipped.
  - A sentinel from another build is simply deleted.
  - The status screen offers "Retry probe", which runs the probe on demand.

### 9.3 Controller and store

```swift
/// Thread-safe snapshot for non-UI code (FEX/Box64 threads in later splits). Lock-protected
/// (os_unfair_lock wrapper or NSLock; iOS 15-compatible). Updated by JITController.
final class JITStatusStore: @unchecked Sendable {
    static let shared: JITStatusStore
    nonisolated var current: JITStatus { get }
}

@MainActor
final class JITController: ObservableObject {
    static let shared: JITController
    @Published private(set) var status: JITStatus
    @Published private(set) var installMethod: InstallMethod
    @Published private(set) var evidence: InstallEvidence
    @Published private(set) var isRequestingTrollStoreJIT: Bool

    init(environment: BundleEnvironment, system: JITSystem, defaults: UserDefaults,
         openURL: @escaping @MainActor (URL) async -> Bool, clock: JITClock)   // JITClock: own iOS 15 seam (Swift Clock needs iOS 16)

    func gatherFacts()                 // at App init; may probe
    func sceneBecameActive()           // first call may request TrollStore JIT; later calls re-check
    func retryTrollStoreJIT()          // Retry button
    func retryProbe()                  // Retry probe button
}

/// Seam over the C layer and sysctl so tests inject facts without a device.
protocol JITSystem: Sendable {
    func csDebugged() -> Bool
    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo
    func probe() -> ProbeOutcome
}
```

**Simulator.** `JITSystem.live` short-circuits in simulator builds:
- It reports `csDebugged` as read but never probes automatically.
- It reports TXM as `absent`, with basis "simulator".
- The status reason is `simulator`.

In the simulator, `csops` reflects host conditions such as an attached debugger, and the TXM check would read the Mac's preboot, so neither is trusted there.

**TrollStore request flow:**
1. At the first `sceneBecameActive()`, if `shouldRequestTrollStoreJIT(... manual: false)`:
   - record the attempt time
   - set `isRequestingTrollStoreJIT` and the reason `trollStoreRequestPending`
   - open `apple-magnifier://enable-jit?bundle-id=<Bundle.main.bundleIdentifier>`
2. Start an **overall deadline** (about 10 s) measured from the open, and poll `csDebugged()` about every 200 ms regardless of scene phase.
3. When `CS_DEBUGGED` appears:
   - mark it `afterTrollStoreRequest`
   - wait a short **grace period** (about 300 ms) so TrollStore's tracer has detached
   - probe, subject to policy, and publish
4. If the deadline passes, or `open` reports failure, publish `trollStoreTimedOut` and clear the flag.
5. `retryTrollStoreJIT()` does the same with `manual: true`.

Every status change is also written to `JITStatusStore.shared`. Later splits read `JITStatusStore.shared.current.usable` from any thread, or observe the controller on the main actor. Consumers must tolerate `usable` changing from false to true.

---

## 10. Device report

### 10.1 Model (`DeviceReport.swift`)

```swift
struct DeviceReport: Codable, Sendable {
    var schemaVersion: Int                   // 1
    var generatedAt: Date                    // ISO-8601 UTC
    var app: AppInfo                         // version, build, commit, packageKind, bundleIdentifier
    var device: DeviceInfo                   // modelIdentifier (hw.machine), chip (display name), cpuFamily (hex)
    var os: OSInfo                           // name, version, build (kern.osversion)
    var install: InstallInfo                 // method, evidence (redacted)
    var jit: JITStatus
    var memory: MemoryInfo                   // availableBytes (os_proc_available_memory) at report time
    var gates: [String: GateResult]          // empty in 01; later splits add e.g. "x18", "guestWindow"
    var notes: String?                       // free text the owner may add before filing
}

struct GateResult: Codable, Sendable { var passed: Bool?; var detail: String; var measuredAt: Date }
```

- **Never included:** the user-assigned device name, UDID or serial number, or anything about games.
- **Chip display names:** a Swift literal table keyed by model identifier, falling back to "unknown". It is used only for display; TXM logic uses `cpuFamily`.
- **Encoding:** `JSONEncoder` with sorted keys and ISO-8601 dates.
- **Evolution:** new data goes inside `gates`. Adding a top-level field bumps `schemaVersion`.

### 10.2 Export (`App/ReportExport.swift`)
- **Copy report:** puts the JSON on the pasteboard.
- **Share report:** a `UIActivityViewController`, bridged into SwiftUI (`ShareLink` needs iOS 16). It shares a temporary `.json` file named from the date, model and install method.

### 10.3 Schema and filing
- **`device-reports/schema.json`** is a JSON Schema (draft 2020-12) of the model. It makes the listed fields required and sets top-level `additionalProperties: false`, which keeps accidental extra data out. `gates` allows any keys whose values have the `GateResult` shape.
- **`scripts/file_device_report.py <path|->`:**
  - Validates the report with a small built-in validator for the schema subset used (no dependency).
  - Rejects unknown `schemaVersion` values.
  - Writes `device-reports/<YYYY-MM-DD from generatedAt>-<modelIdentifier>-<install.method>-<8-char sha256 of canonical JSON>.json` and prints the path.
  - If an identical file already exists, it succeeds without writing.

---

## 11. Packaging, signing and verification

### 11.1 Archive (`scripts/archive.sh`)

1. `make project`.
2. `xcodebuild archive -project Eikon.xcodeproj -scheme Eikon -configuration Release -destination 'generic/platform=iOS' -archivePath build/Eikon.xcarchive CODE_SIGNING_ALLOWED=NO`.
3. Fail if `build/generated/Acknowledgements.json` was missing.
4. Fail if any Mach-O has a slice other than arm64. Thin fat binaries with `lipo -thin arm64`. There are none in 01; the check is there for later splits.

### 11.2 Packaging (`scripts/package.sh ipa|tipa|deb`)

**Common steps:**
1. `ditto` the `.app` from the archive into a fresh stage, with `COPYFILE_DISABLE=1`.
2. Set `EKPackageKind` with PlistBuddy.
3. Sign once at bundle level: `ldid -S<packaging/entitlements/<kind>.plist> -I<bundle id from Info.plist> Eikon.app`. Procursus ldid signs nested code first and seals resources.
   - If ldid's behaviour turns out to apply the entitlements to nested Mach-O files as well, fall back to: sign nested code with `ldid -S` (no entitlements), then run the bundle-level call. The verifier decides which is correct.
4. Read the version back from the staged Info.plist, and fail if it differs from `VERSION`.

**Per kind:**
- **ipa and tipa:** make `Payload/Eikon.app`, then `zip -qr -X --symlinks`, excluding `._*`, `.DS_Store` and `__MACOSX`. Output: `dist/Eikon-<v>.ipa` and `dist/Eikon-<v>.tipa`. These zips are not byte-reproducible (mtimes), and nothing assumes they are.
- **deb:**
  1. Stage `var/jb/Applications/Eikon.app`. Put `LICENSE` and `THIRD_PARTY_NOTICES.md` in `var/jb/usr/share/doc/com.getboolean.eikon/`.
  2. Write `DEBIAN/control` from `control.in`, with `Installed-Size` from `du -sk` of `var`. Install `postinst` and `prerm` with mode 0755.
  3. `chmod -R u=rwX,go=rX` the stage.
  4. Build with `SOURCE_DATE_EPOCH=<last commit time> dpkg-deb --root-owner-group -Zxz -b`, giving `dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb`.
- **`make package`** also writes `dist/SHA256SUMS`.

**Deb control fields:**
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
- `Description`: short and honest, with no program titles

**Maintainer scripts:**
- Both prepend `/var/jb/usr/bin:/var/jb/bin` to `PATH` and use `command -v uicache`.
- `postinst` on `configure` runs `uicache -p /var/jb/Applications/Eikon.app`.
- `prerm` on `remove` (not `upgrade`) runs `uicache -u /var/jb/Applications/Eikon.app`.
- Both exit 0 when `uicache` is absent. Procursus's uikittools trigger on `/var/jb/Applications` normally covers this.
- Whether `uicache` must run as `mobile` on iOS 15+ is checked on the first Dopamine install.

### 11.3 Entitlements (`packaging/entitlements/`)

| Key | deb | tipa | ipa |
|---|---|---|---|
| `com.apple.private.security.no-sandbox` | true | true | – |
| `get-task-allow` | – | true | true |
| `com.apple.developer.kernel.increased-memory-limit` | true | true | true |
| `com.apple.developer.kernel.extended-virtual-addressing` | true | true | true |
| `com.apple.private.memorystatus` | true | true | – |

- The **deb** leaves out `get-task-allow`: Dopamine doesn't need it, and on iOS 16 it would require Developer Mode.
- The **tipa** needs `get-task-allow` for TrollStore's enable-jit, which means **Developer Mode on iOS 16+**. This is stated in the README and the depiction.
- The **ipa** lists the public keys so AltStore requests those App ID capabilities. AltStore replaces the entitlements with the profile's.

`packaging/entitlements/README.md` records:
- each key's purpose and which install methods honour it
- what is unverified (the memory keys under Dopamine ad-hoc signing, and the AltStore free-team capability grants), with the report's `memory.availableBytes` as evidence
- why `platform-application` is not used
- the forbidden list

Later splits add rows: 08 for memory, 05 and 07 for address space.

### 11.4 Verifier (`scripts/verify_artifacts.py dist/`)

It extracts each artifact to a temporary directory (zip for ipa and tipa; `dpkg-deb -x` and `-f` for the deb) and checks:

**Layout and control**
- ipa and tipa contain exactly one `Payload/Eikon.app`.
- The deb has the app under `var/jb/Applications/` and nothing outside `var/jb/`.
- The deb control has `Architecture: iphoneos-arm64`, `Package: com.getboolean.eikon`, and a `Version` equal to `VERSION`.

**Version and stamp**
- `CFBundleShortVersionString` equals `VERSION`.
- `CFBundleVersion` is identical in all three artifacts.
- `EKPackageKind` matches the artifact kind.

**Hygiene**
- No `._*`, `.DS_Store` or `__MACOSX`.

**Signatures and entitlements**
- The main binary (`ldid -e`) has every key in its kind's entitlements file with the right value, and **no forbidden key**.
- The main binary's code directory includes a resource-directory (CodeResources) hash.
- `_CodeSignature/CodeResources` exists.
- Every nested Mach-O is signed and carries no entitlements.

**Same binary across artifacts**
- The three main executables have the same `LC_UUID`.
- They have identical hashes of every segment except `__LINKEDIT`.

Expectations come from the entitlements files and `VERSION`, with no duplicated constants.

---

## 12. Publishing to `eikon-source`

### 12.1 Target state of `getBoolean/eikon-source` (`main`)

```
README.md            # what the repo is, the Sileo URL, "package files only"
docs/                # owned wholesale by build_index.py
  .nojekyll  Release  Packages  Packages.xz  Packages.zst
  depiction.json  index.html  CydiaIcon.png  icon.png
```

This repo holds no debs, scripts or workflows. Pages is served from `main` `/docs`.

**First-publish migration.** Replace everything under `docs/`, and rewrite `README.md` from `packaging/repo/README.md.in`. Remove any other stray files, which should not exist; the implementer lists the repo first and asks before deleting anything unexpected.

### 12.2 `scripts/repo/build_index.py`

```python
def build_index(deb: Path, asset_url: str, out_docs: Path, templates: Path, icon_src: Path,
                filename_mode: Literal["absolute", "relative"] = "absolute") -> None:
    """Rewrite out_docs entirely (touch nothing outside it), keeping only the latest version.
    Packages: one stanza = the deb's control fields + Filename (asset_url, or debs/<name> in
    relative mode) + Size, MD5sum, SHA1, SHA256 of `deb`. Packages.xz / .zst: compressed copies.
    Release: Origin, Label, Suite, Version, Codename, Architectures: iphoneos-arm64,
    Components: main, Description, Date (RFC 2822 UTC), then `MD5Sum:` and `SHA256:` sections
    listing exactly the Packages files written, with sizes. Renders depiction.json and
    index.html from templates (version, date, links to the eikon repo, release, license,
    notices; .tipa Developer Mode note). Writes .nojekyll and icons."""
```

- **Input deb.** The `deb` passed in is **downloaded from `asset_url`**, so `Packages` hashes match exactly what Sileo downloads.
- **Control fields** are read with `dpkg-deb -f`. It is available on macOS through Homebrew and on `ubuntu-latest`.
- **Asset URL** is `https://github.com/getBoolean/eikon/releases/download/v<ver>/com.getboolean.eikon_<ver>_iphoneos-arm64.deb`. GitHub redirects it to object storage, and Sileo following that redirect is **verified on the first device install**.
- **Relative mode** is the fallback if Sileo fails there. The deb is then committed under `docs/debs/` while it is under 100 MB.
- **Depiction:**
  - `DepictionTabView`, `minVersion` "0.4", `tintColor` #c6f54a, no empty `headerImage`
  - a Details tab with the description, version, compatibility (iOS 15.0+, Dopamine rootless), and "JIT is enabled automatically on Dopamine"
  - a Licenses tab (GPL-3.0-or-later, and a link to `THIRD_PARTY_NOTICES.md` at the tag)
  - no demo names, no "Wine under FEX", no "not a live source"
  - honest about the prototype's state

### 12.3 One-time setup (owner-run or owner-approved; in `README.md`)

These are outward-facing actions. The implementer prepares each one and asks before running it.

1. **Deploy key.** Create an SSH deploy key with write access on `eikon-source`. Store the private key as the secret `EIKON_SOURCE_DEPLOY_KEY` in an `eikon` **GitHub Environment** named `eikon-source`, with the owner as required reviewer.
2. **Pages.** After the first publish puts the files in place, enable Pages:
   `gh api -X POST repos/getBoolean/eikon-source/pages -f 'source[branch]=main' -f 'source[path]=/docs'`
   If Pages already exists, use `PUT` on the same endpoint instead.
3. **Repo description.** Update the `eikon-source` repo description.

### 12.4 Local `scripts/repo/publish.sh`

This is the fallback when CI can't publish. CI is canonical.

1. **Preflight.** Require all of:
   - a clean tree
   - `HEAD` tagged `v$(VERSION)`
   - verified `dist/`
   - **no existing GitHub Release** for the tag. The script refuses otherwise; it never replaces assets.
2. **Release.** `gh release create v<ver>` with the three artifacts and `SHA256SUMS`.
3. **Index.** Download the deb back from the asset URL, clone `eikon-source` into `build/eikon-source`, and run `build_index.py`.
4. **Push.** Commit ("Publish com.getboolean.eikon <ver>"), push, and print the Sileo URL.

It supports `--dry-run`, and it prints each outward-facing action before running it.

---

## 13. CI (GitHub Actions)

All actions are pinned by commit SHA. Top-level `permissions: contents: read`. Checkout uses `fetch-depth: 0`.

### 13.1 `ci.yml` (push, pull_request)
- **`scripts`** (`ubuntu-latest`): set up uv, then run `uv run pytest tests/` and `uv run scripts/credits.py check`.
- **`build`** (`macos-latest`, newest installed Xcode through `DEVELOPER_DIR`):
  1. `brew install xcodegen ldid-procursus dpkg uv`
  2. `make test-swift archive package verify`
  3. Upload `dist/` as a workflow artifact.
- This workflow never publishes.

### 13.2 `release.yml` (push of tags `v*` only)
1. **`build`** (macOS): `version.sh --check-tag "$GITHUB_REF_NAME"`, then `make all`, then upload `dist/`.
2. **`release`** (needs `build`; `permissions: contents: write`): `gh release create` with the artifacts and `SHA256SUMS`. It fails if the release exists.
3. **`publish`** (needs `release`; `ubuntu-latest`; `environment: eikon-source`):
   1. A step checks that the deploy-key secret is present, reading it through `env` because job-level `if:` can't read secrets. If the secret is absent, it prints a clear skip message and exits successfully.
   2. Download the deb from the release asset URL.
   3. Check out `getBoolean/eikon-source` with the SSH key.
   4. Run `build_index.py`, then commit and push as a bot identity.
- `concurrency: publish` stops two tags racing on `eikon-source`.

---

## 14. Status screen (`App/StatusView.swift`)

A `NavigationView` with a `List`, in these sections:

1. **Eikon:** version (build), commit, package kind, bundle id.
2. **Install:** detected method, in words.
3. **JIT:**
   - a large **Usable / Not usable** state
   - source, `CS_DEBUGGED` (and when it was seen), probe outcome, TXM (state, enforced, basis)
   - a "Waiting for TrollStore…" row while a request is pending
   - the localised reason text when not usable
   - **Retry JIT** on TrollStore installs when not usable and no request is pending
   - **Retry probe** when the reason is `probeSkippedAfterCrash` or `probeFailed`
4. **Device:** model identifier, chip, iOS version and build, available memory.
5. **Report:** Copy report, Share report.

All user-facing strings live in `Localizable.strings`, ready for split 09. Dynamic Type and dark mode use system defaults.

---

## 15. Testing (few, behavioral)

**Swift Testing (`EikonKitTests`)**, with injected facts through `JITSystem`, `BundleEnvironment`, a test `UserDefaults` suite, and a controllable clock:
- **Every non-usable status carries a reason, and usable ones don't.** Walk representative fact combinations: each install method × `CS_DEBUGGED` × TXM × probe outcome.
- **The probe is never requested when unsafe:** no `CS_DEBUGGED`, TXM enforced or undetermined on iOS 26+, simulator, or a sentinel from this build.
- **TrollStore JIT is requested once, then suppressed.** It is requested automatically once per process only on TrollStore installs. A second automatic attempt within the cooldown is suppressed (compare `lastAttempt = now` with `.distantPast`). A manual retry bypasses both.
- **Attribution needs a request.** `trollStore` is credited only when `CS_DEBUGGED` appears after a request.
- **The request always ends.** In the controller, a pending request reaches either usable or `trollStoreTimedOut` by the deadline, with the clock controlled.
- **Install detection** from fake layouts: a TrollStore marker, a Dopamine root with and without the marker, a provisioning profile, none.

**pytest (`tests/`):**
- **Credits:** a temp repo with a credited submodule passes. Adding an uncredited submodule fails, and so does a missing license file.
- **Patches:** applying twice gives the same tree, the superproject sees no new submodule commit, and a conflicting patch fails with the component named.
- **Repo index:** every hash and size in `Release` matches its file, and `Packages` hashes match the deb.
- **Device-report filer:** accepts a valid report, rejects an invalid one, and refiling is a no-op.
- **Version guard:** a tag/`VERSION` mismatch fails.

**Not tests:**
- The artifact verifier runs on real artifacts in CI.
- Device behaviour is proven by filed device reports.

---

## 16. Device verification runbook (`device-reports/README.md`)

### iPad Pro 12.9" 6th gen (M2), iPadOS 17.0

**TrollStore**
1. With Developer Mode on, install `Eikon-<v>.tipa` and launch.
2. Expect TrollStore to open and return, then usable with source `trollStore`.
3. File the report.
4. Disable TrollStore's URL scheme and relaunch after the cooldown. Expect `trollStoreTimedOut`. Re-enable the scheme, press Retry JIT, and expect usable.
5. Turn Developer Mode off and try to launch. Record what happens (a TrollStore install warning, a launch refusal, or a launch without JIT) in the report notes.

**Dopamine 3, if it supports this device**
1. Uninstall the `.tipa`; both use the same bundle id.
2. Add `https://getboolean.github.io/eikon-source/` in Sileo, install Eikon, and launch.
3. Expect usable at first paint with source `dopamine`.
4. File the report. It also answers the questions about the data and home directory, the release-asset redirect, and uicache.
5. Turn "Allow JIT in Apps" off and relaunch. Expect `dopamineJITOff`.

If Dopamine 3 can't be used on this device, note it. The deb is then desktop-verified only.

**Debug loop (optional)**
- An Xcode-debugged run exercises the real probe (section 7.3).

### iPhone 13 mini (A15), iOS 27.0

**AltStore**
1. Install `Eikon-<v>.ipa` with AltStore.
2. Record any capability errors for `increased-memory-limit` or `extended-virtual-addressing`, and whether the install succeeds.
3. Launch. Expect **not usable, reason `txmEnforced`**, with or without an enabler.
4. File the report.

### Filing
- File every report with `uv run scripts/file_device_report.py` and commit it.

---

## 17. Order of work

1. **Environment and skeleton:**
   - `make doctor`, confirming uv/Python 3.12 and the tools
   - `VERSION`, `LICENSE`, `licenses/`, `.gitignore`, `Makefile`
   - doctor/bootstrap scripts, `pyproject.toml`, `.python-version`, pytest scaffold
2. Version script and guard.
3. XcodeGen project, xcconfigs, the EikonKit skeleton, and an app that builds and launches in the simulator.
4. **Minimal `ci.yml`** (scripts plus the build/test job), to surface runner problems early.
5. Submodule/patch convention and `apply_patches.py`, with tests.
6. Credits pipeline, with tests. Generate `THIRD_PARTY_NOTICES.md`, and wire in the acknowledgements JSON.
7. Install-method detection, with tests.
8. The JIT C layer, then the policy, store and controller, with tests.
9. Device report model, schema, filer (with tests), and export.
10. Status screen.
11. Packaging (entitlements, `package.sh`) and the verifier. Extend `ci.yml`.
12. Repo index generator (with tests) and `publish.sh`.
13. `release.yml`, and the environment and deploy-key setup (with owner approval).
14. **First release `v0.1.0`:**
    - tag, and CI publishes
    - enable Pages (with owner approval)
    - run the device runbook and file the reports

---

## 18. Risks and open points

| Risk | Handling |
|---|---|
| Dopamine 3 may not support the M2 iPad on 17.0 | The deb is desktop-verified, which is recorded. It can be checked on any Dopamine device later. |
| Sileo may not follow GitHub's release-asset redirect | Verify on the first install. Fallback: `filename_mode="relative"` with the deb committed while it is under 100 MB. |
| `.tipa` with Developer Mode off may not launch | Documented as a requirement. The runbook records the actual behaviour. |
| AltStore free team can't grant a capability, which may fail the install | Recorded on the first `.ipa` install. If it fails, drop that key from `ipa.plist` and note it in the entitlements README. |
| `uicache` as root in `postinst` on iOS 15+ | Check on the first Dopamine install, and adjust to run as `mobile` if needed. |
| The simulator can't exercise JIT-positive paths | Policy and controller tests with injected facts, plus the Xcode-debugged device run and device reports. |
| TXM heuristic wrong for some CPU families | It is a data table keyed by CPU family. Unknown families are treated as enforced, and device reports correct the table. |
| Memory entitlements may not be enforced under Dopamine ad-hoc signing | Reports' `availableBytes` is the evidence, and 08 acts on it. |
| Shallow CI checkout breaks build numbers | `fetch-depth: 0`, and `version.sh` fails on a shallow clone. |
| Re-uploaded release assets break Sileo's hashes | Assets are never replaced, CI is canonical, and the index hashes the downloaded asset. |
| The `macos-latest` runner's Xcode may lag Xcode 27 | Select the newest installed Xcode. iOS 15 is a valid target for Xcode 16+. |
| Python inside Xcode | Avoided: no build-phase Python, and all scripts run through `uv run` on Python 3.12. |
