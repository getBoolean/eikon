# Section 01: Skeleton and tooling

## Goal

Create the repository skeleton that every later section builds on:

- the top-level files (`VERSION`, `LICENSE`, `licenses/`, `.gitignore`, an updated `README.md`)
- the Python tooling (`.python-version`, `pyproject.toml`, `uv.lock`, the `tests/` scaffold)
- the `Makefile`, the single entry point for every task
- three shell scripts: `scripts/doctor.sh`, `scripts/bootstrap.sh`, `scripts/version.sh`
- the version-guard tests

When this section is done, `make doctor`, `make version`, `make check` and `make test-scripts` work. Targets whose scripts arrive in later sections exist but are stubs.

## Background

Eikon is an iPhone and iPad app. The repository `github.com/getBoolean/eikon` is public and today holds only planning documents, a `README.md`, a `.gitignore` and a `.vscode/` folder. There is no source, no build system, no submodules and no license file. This section adds the first real files.

Project-wide decisions that shape this section:

- **Build system.** XcodeGen (`project.yml`) plus `.xcconfig` files plus a Makefile that calls scripts. The generated `.xcodeproj` is never committed. The XcodeGen project itself comes in section 02.
- **Scripts.** Python 3.12 run through `uv run`, pinned by `.python-version`, standard library only. pytest is the only dev dependency. No Python ever runs inside Xcode build phases. (The Mac's system `/usr/bin/python3` is 3.9.6 and lacks `tomllib`, which is why uv is used.)
- **Compilers.** `~/.swiftly/bin` comes before `/usr/bin` on the development Mac's PATH, so every script invokes compilers and Apple tools through `xcrun`.
- **Signing tool.** The ProcursusTeam `ldid`, installed from the Homebrew formula `ldid-procursus`. The Homebrew formula named `ldid` is saurik's older version and is the wrong tool.
- **Versioning.** `VERSION` is the only source of the marketing version. The first version is `0.1.0`.
- **License.** The project is GPL-3.0-or-later.
- **Development Mac:** macOS 27, Xcode 27.0 (iOS SDK 27.0), Swift 6.4. Missing today: `xcodegen`, `ldid-procursus`, `dpkg`.

Cross-cutting rules that apply here:

- **Tests stay few and behavioral.** They check what a feature does. They never assert exact file contents, constant values, message texts or internal structure (owner's rule).
- **No program or game titles** anywhere: code, docs, test names, commit messages. Don't touch `/Volumes/Games`.
- **Owner approval first** for anything outward-facing (pushes, releases, repo settings). `bootstrap.sh` installs software, so it runs only when the owner asks.

## Dependencies

- **Depends on:** nothing. This is the first section.
- **Blocks:** section-02-xcode-project, section-03-patch-convention, section-04-credits-pipeline.
- Later sections replace the Makefile stubs listed below with real recipes. They don't change the stubs' names.

## Target layout (whole split, for orientation)

This section creates only the items marked **(01)**. The rest shows where later sections put things, so the Makefile and `.gitignore` are written with the final layout in mind.

```
eikon/
  VERSION                 (01) "0.1.0"
  LICENSE                 (01) GPL-3.0 full text
  licenses/               (01) license texts named <SPDX-id>.txt
    GPL-3.0-or-later.txt  (01)
  README.md               (01, updated)
  Makefile                (01)
  .python-version         (01)
  pyproject.toml          (01)
  uv.lock                 (01)
  .gitignore              (01, extended)
  scripts/
    doctor.sh             (01)
    bootstrap.sh          (01)
    version.sh            (01)
    deps.py                     section 03 (replaced apply_patches.py)
    credits.py                  section 04
    archive.sh  package.sh  verify_artifacts.py   section 10
    file_device_report.py       section 08
    repo/build_index.py  repo/publish.sh           section 11
  tests/                  (01) pytest suite for scripts
    conftest.py           (01)
    test_version.py       (01)
  project.yml  Config/  App/  Packages/EikonKit/   section 02
  third_party/  patches/                           sections 03, 04
  THIRD_PARTY_NOTICES.md                           section 04
  packaging/                                       sections 10, 11
  device-reports/                                  sections 08, 12
  .github/workflows/                               sections 02, 10, 12
```

Generated output goes under `build/` (for example `build/generated/Version.xcconfig`), and packaged artifacts go under `dist/`. Neither is committed.

---

## Tests first

Write these before `scripts/version.sh`. They are the only tests in this section. Tooling files, the Makefile, `doctor.sh` and `bootstrap.sh` have no unit tests: they are checked by running them, and CI (section 02) runs the Makefile end to end.

### `tests/conftest.py`: temporary git repo helper

A small shared helper that sections 03 and 04 will reuse. It provides a pytest fixture (for example `git_repo`) that:

- creates a fresh git repository in `tmp_path` with a fixed default branch
- sets a local author name and email and turns off commit signing, so commits work on any machine and on CI
- offers helpers to write a file, commit, tag, and run git in that repo

Pass the identity through the repository's local config or through `GIT_AUTHOR_*` / `GIT_COMMITTER_*` environment variables. Never touch the user's global git config.

```python
@pytest.fixture
def git_repo(tmp_path) -> "GitRepo":
    """A new git repo with local identity configured. GitRepo offers
    write(path, text), commit(message), tag(name), git(*args) and a .path attribute."""
```

Also provide a helper that runs a repo script (for example `scripts/version.sh`) by its absolute path in the Eikon checkout, with the working directory set to the fixture repo, and returns the completed process. Tests assert on exit status, not on output text.

**As built:** everything is a fixture, so tests never import from `conftest`: `git_repo`, `make_repo(name)` (a factory for extra repos, such as a clone origin) and `run_script(script, *args, cwd=, env=None)`. Every git command and script under test runs with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, so the user's own git config (hooks, templates, signing) is neither read nor changed.

### `tests/test_version.py`: version guard

Three behavioral tests, each run against a temporary git repo:

1. **A tag that disagrees with `VERSION` fails `--check`.** Write `VERSION` = `1.2.3`, commit, tag `HEAD` as `v1.2.4`: `version.sh --check` exits non-zero. Delete that tag and tag `HEAD` as `v1.2.3`: `--check` exits zero.
2. **`--check-tag` compares the given tag with `VERSION`.** With `VERSION` = `1.2.3`, `--check-tag v1.2.4` exits non-zero and `--check-tag v1.2.3` exits zero.
3. **A shallow clone can't generate a build number without the override.** Make an origin repo with at least two commits and a valid `VERSION`, then clone it with `git clone --depth 1 file://<origin>` (the `file://` form is required, or git ignores `--depth` for local paths). In the clone, running `version.sh` with no arguments and without `EIKON_BUILD_NUMBER` exits non-zero. With `EIKON_BUILD_NUMBER` set to a positive integer, it exits zero and the generated file exists.

Don't assert the generated file's contents, the message texts, or any specific settings.

---

## Implementation

### 1. `VERSION`

One line: `0.1.0`, with a trailing newline. It must match `^\d+\.\d+\.\d+$` after trimming whitespace, because `CFBundleShortVersionString` must be numeric. It replaces a phantom `1.0.0` entry in the old package index whose deb was never uploaded.

### 2. `LICENSE` and `licenses/`

- `LICENSE`: the unmodified GNU GPL version 3 text. Copy it from `https://www.gnu.org/licenses/gpl-3.0.txt`; don't retype it.
- `licenses/GPL-3.0-or-later.txt`: the same text. The `licenses/` directory holds one text per SPDX id used by the project or its components, named `<SPDX-id>.txt`. The credits pipeline (section 04) requires a file here for every id a manifest entry uses.

### 3. `.gitignore`

Keep the existing entries, including the planning-tool lines:

```
planning/deep_project_session.json
planning/**/deep_plan_config.json
```

Add:

```
build/
dist/
*.xcodeproj
DerivedData/
.venv/
__pycache__/
.pytest_cache/
.DS_Store
```

`uv.lock` is **not** ignored; it is committed.

### 4. Python tooling

- **`.python-version`:** `3.12`. uv reads it to pick (and if needed download) the interpreter.
- **`pyproject.toml`:** a uv project that is not a package.
  - `[project]`: name `eikon-scripts` (or similar), a version, `requires-python = ">=3.12"`, and no runtime dependencies. Scripts use the standard library only.
  - `[dependency-groups]`: `dev = ["pytest"]`. uv installs the dev group by default for `uv run`.
  - `[tool.uv]`: `package = false`.
  - `[tool.pytest.ini_options]`: `testpaths = ["tests"]`.
- **`uv.lock`:** produced by `uv lock` and committed, so CI and the Mac resolve the same pytest.
- **`tests/`:** `conftest.py` and `test_version.py` as above. No `__init__.py` is needed.

`uv run pytest tests/` must pass on macOS and on `ubuntu-latest` (the CI scripts job in section 02 runs it there).

### 5. `scripts/version.sh`

Bash, `set -euo pipefail`, executable. It must run on macOS's `/bin/bash` 3.2 and on Linux bash, so avoid bash 4 features (associative arrays, `${var,,}`, `mapfile`). It works on the git repository that contains the current working directory (`git rev-parse --show-toplevel`), not on the script's own location. That lets the tests point it at temporary repos. It reads `VERSION` from that repo's root.

**Default mode (no arguments): generate.** Write `<root>/build/generated/Version.xcconfig` with three settings:

| Setting | Source |
|---|---|
| `MARKETING_VERSION` | the trimmed contents of `VERSION` |
| `CURRENT_PROJECT_VERSION` | `EIKON_BUILD_NUMBER` if set, else `git rev-list --count HEAD` |
| `EIKON_GIT_COMMIT` | `git rev-parse --short HEAD`, plus `-dirty` if tracked files have uncommitted changes |

Rules:

- Validate `VERSION` against `^[0-9]+\.[0-9]+\.[0-9]+$`, and fail if it doesn't match or is missing.
- **Shallow-clone guard.** If `git rev-parse --is-shallow-repository` prints `true` and `EIKON_BUILD_NUMBER` is not set, fail with a message saying the commit count would be wrong and suggesting a full clone (CI uses `fetch-depth: 0`) or the override.
- `EIKON_BUILD_NUMBER`, when set, must be a positive integer. Fail otherwise.
- Fail cleanly if the repo has no commits.
- "Dirty" means changes to tracked files only. Untracked files don't count. Refresh the index first (`git update-index -q --refresh`), then use `git diff-index --quiet HEAD --`.
- Write the file atomically: write a temporary file in the same directory, then `mv` it into place. Create `build/generated/` if needed.
- Use the usual xcconfig form, one `KEY = value` line per setting, with a comment line saying the file is generated.

**`--check`.** Validate the `VERSION` format. Then list the `v*` tags that point at `HEAD` (`git tag --points-at HEAD --list 'v*'`). If there are any, every one must equal `v<VERSION>`; any other `v*` tag on `HEAD` fails. No tag on `HEAD` passes. `--check` never writes files and doesn't apply the shallow guard.

**`--check-tag <tag>`.** Used by the release workflow (section 12) with `$GITHUB_REF_NAME`. Validate the `VERSION` format and require `<tag>` to equal `v<VERSION>` exactly. A missing argument is a usage error.

Any other argument is a usage error. Every failure prints a one-line reason to stderr and exits non-zero.

**Where the output is used (context only).** Section 02's `Config/Base.xcconfig` includes `build/generated/Version.xcconfig` optionally (`#include?`) and provides fallbacks, so the project opens in Xcode before `make version` has run. The Info.plist then reads `$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)` and `$(EIKON_GIT_COMMIT)`.

### 6. `scripts/doctor.sh`

Bash, executable, macOS only (it is not run on Linux CI). It checks each tool, prints one line per tool (found or missing, with a hint), and exits non-zero if anything is missing. It never installs anything.

Checks:

- **Xcode:** `xcode-select -p` succeeds, `xcodebuild -version` works, and `xcrun --sdk iphoneos --show-sdk-path` finds an iphoneos SDK.
- **`xcodegen`** on PATH.
- **`ldid`, Procursus variant:** `ldid` is on PATH and is the Procursus build. It counts as Procursus if its version or usage output mentions Procursus (case-insensitive) or lists the `-M` option. If an `ldid` exists but isn't the Procursus one, report it as wrong, and hint that the Homebrew `ldid` formula conflicts with `ldid-procursus`.
- **`dpkg-deb`, `uv`, `gh`, `zstd`, `xz`** on PATH.
- **Python 3.12 through uv:** `uv python find 3.12` succeeds. If it doesn't, the hint is that `uv run` will download it on first use; report this as a warning, not a failure.

Hints name the Homebrew formula to install, and point to `make bootstrap`.

### 7. `scripts/bootstrap.sh`

Bash, executable, macOS only. **It runs only when the owner asks for it.** No other target or script calls it.

- Requires `brew`. If Homebrew is missing, it says so and exits non-zero.
- Installs only the tools that are missing, from the formulas `xcodegen`, `ldid-procursus`, `dpkg` and `uv` (the plan's core set), and also `gh`, `zstd` and `xz` when missing, so `make doctor` passes afterwards. It runs a single `brew install <missing…>` and prints the command first.
- If the conflicting `ldid` formula is installed (`brew list --formula ldid` succeeds), it prints a warning telling the owner to `brew uninstall ldid` before installing `ldid-procursus`. It does not uninstall anything itself.
- It can't install Xcode. If Xcode is missing, it says so.
- It finishes by running `scripts/doctor.sh` and exits with its status.

### 8. `Makefile`

The entry point for every task. Use `.PHONY` for every target, `SHELL := /bin/bash`, and recipes that call scripts rather than holding logic. Python always runs as `uv run …`.

Full target list for the whole split. **Real** means implemented in this section; **stub** means the target exists now, and the named section replaces its recipe.

| Target | Does | In 01 |
|---|---|---|
| `doctor` | `scripts/doctor.sh` | real |
| `bootstrap` | `scripts/bootstrap.sh` | real |
| `version` | `scripts/version.sh` → `build/generated/Version.xcconfig` | real |
| `generated` | `version`, then `uv run scripts/credits.py app-json build/generated/Acknowledgements.json` | real: the credits step is skipped with a note while `scripts/credits.py` doesn't exist (section 04) |
| `project` | `generated`, then `xcodegen generate` | stub (section 02) |
| `check` | `uv run scripts/credits.py check`, then `scripts/version.sh --check` | real: the credits step is skipped with a note while `scripts/credits.py` doesn't exist (section 04) |
| `test` | `test-swift` + `test-scripts` | real |
| `test-swift` | `xcodebuild test -scheme Eikon` on the newest available iPhone simulator | skipped with a note while `project.yml` doesn't exist (section 02 supplies the recipe) |
| `test-scripts` | `uv run pytest tests/` | real |
| `archive` | `project`, then `scripts/archive.sh` → `build/Eikon.xcarchive` | stub (section 10) |
| `ipa` / `tipa` / `deb` | `scripts/package.sh <kind>` → `dist/` | stub (section 10) |
| `package` | all three kinds, plus `dist/SHA256SUMS` | stub (section 10) |
| `verify` | `uv run scripts/verify_artifacts.py dist/` | stub (section 10) |
| `all` | `check test archive package verify` | real as a composition; fails at the first stub until section 10 |
| `publish` | `scripts/repo/publish.sh` | stub (section 11) |
| `apply-patches` / `unpatch` (replaced in section 03 by `fetch-deps`, `verify-deps`, `pin-dep`) | `uv run scripts/apply_patches.py apply` / `restore` | stub (section 03) |
| `clean` | removes `build/` and `dist/` | real |

**Stub behaviour.** A stub prints which section implements it (for example "`archive`: not implemented yet (section 10)") and exits 1, so nothing passes silently.

**Skip behaviour.** The two skips (the credits step while `credits.py` is absent, and `test-swift` while `project.yml` is absent) print a note and continue with success. They keep `make check` and `make test` usable from this section on. The sections that add those files remove the skip.

`make test` must pass after this section: `test-swift` skips, and `test-scripts` runs the version tests.

### 9. `README.md` update

Keep the existing text's substance and tone: what Eikon is, the name's origin and pronunciation, that it is an unfinished prototype, the package id, the pointer to the separate Sileo source repo, and that there is no JIT bypass and no exploit. Add these sections:

- **Requirements:** macOS with Xcode (iOS SDK), Homebrew, and the tools `make doctor` checks. Python comes through uv. iOS 15.0 is the minimum OS on devices.
- **Building:** `make doctor`, then `make bootstrap` only if tools are missing, then `make all`. List the main targets briefly (`version`, `check`, `test`, `archive`, `package`, `verify`, `clean`), and note that `all` produces one app binary packaged three ways. Note that the `.xcodeproj` is generated and not committed.
- **Install methods and artifacts:**
  - Dopamine rootless deb (`com.getboolean.eikon`, `iphoneos-arm64`, installed at `/var/jb/Applications/Eikon.app`), supported on Dopamine 2 for iOS 15.0–16.6.1
  - `Eikon.tipa` for TrollStore, up to iOS 17.0. On iOS 16 and later, **Developer Mode must be on**, because the `.tipa` carries `get-task-allow`, which TrollStore's enable-JIT feature needs.
  - `Eikon.ipa` for AltStore, on current iOS
- **JIT behaviour**, briefly:
  - Dopamine grants JIT automatically when its "Allow JIT in Apps" setting is on.
  - On TrollStore 2.0.12 or later, the app asks TrollStore once to enable JIT, and TrollStore returns to the app.
  - On AltStore, the app only detects JIT that an external tool has provided.
  - On devices with Apple's Trusted Execution Monitor (iOS 26 and later on chips that have it), the app reports JIT as not usable, and the routes that don't need JIT still work.
  - The status screen shows whether JIT is usable, where it came from, and a reason when it isn't.
- **License:** GPL-3.0-or-later (see `LICENSE`). Third-party notices will be in `THIRD_PARTY_NOTICES.md`.

Don't name any enabler app in UI-facing wording, and don't mention any program or game titles. Leave the debug-loop note to section 02 and the one-time publishing setup to section 11.

---

## Done when

1. `make doctor` runs, lists every tool, and exits non-zero while `xcodegen`, `ldid-procursus` or `dpkg` are missing. After the owner approves `make bootstrap`, it exits zero.
2. `make version` writes `build/generated/Version.xcconfig`, and the file is ignored by git.
3. `make check` passes on the repo as committed.
4. `make test` passes: the version tests pass under `uv run pytest tests/`, and `test-swift` reports its skip.
5. Each stub target exits non-zero and names the section that implements it.
6. `make clean` removes `build/` and `dist/`.
7. `git status` shows no generated files after a build (`build/`, `dist/`, `.venv/` and caches are ignored), and `uv.lock` is committed.

---

## Implementation notes (as built)

Files: `VERSION`, `LICENSE`, `licenses/GPL-3.0-or-later.txt` (both the unmodified gnu.org text), `.gitignore`, `README.md`, `.python-version`, `pyproject.toml`, `uv.lock`, `Makefile`, `scripts/{version,doctor,bootstrap}.sh`, `tests/{conftest,test_version}.py`. There are three tests, as planned.

Deviations, and choices the plan left open:

- **`archive` has no `project` prerequisite yet.** With it, `make archive` failed on the section-02 `project` stub and named the wrong section. Section 10 adds the prerequisite along with the real recipe.
- **`test-swift`** fails as a section-02 stub once `project.yml` exists. Section 02 replaces the whole `if` block.
- **`.gitignore`** also ignores `planning/**/deep_implement_config.json`, the implementation tool's machine-specific state.
- **`version.sh`:**
  - An empty `EIKON_BUILD_NUMBER` counts as unset, because CI can export empty strings.
  - `VERSION` is trimmed at its ends only. Inner whitespace, or a second non-empty line, fails validation.
  - A git error while listing tags or checking for changes fails the script instead of passing silently or adding `-dirty`.
  - The generated file is mode 644.
- **`bootstrap.sh`** decides whether to install `ldid-procursus` with `brew list --formula ldid-procursus`, so a different `ldid` on PATH can't stand in for it.
- **`doctor.sh`** matches `-M` only as a separate option word. When uv is missing, it prints a warning line for Python.

The review trail is in `../implementation/code_review/section-01-*.md`.
