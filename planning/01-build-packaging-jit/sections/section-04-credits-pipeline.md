# Section 04: Credits pipeline

## Goal

Build the licensing and credits pipeline that protects every third-party component later splits add. It has four parts:

- a manifest, `third_party/credits.toml`
- a checker, `scripts/credits.py check`, run by `make check` and CI
- a generator for the committed `THIRD_PARTY_NOTICES.md`
- a generator for the app's acknowledgements JSON, wired into the Xcode project through `make generated`

Split 01 has no third-party components, so the manifest is empty and the generated outputs are near-empty. The work here is the guard itself. From now on, adding a submodule without crediting it fails CI.

## Background

Eikon is an iPhone and iPad app released under GPL-3.0-or-later. Later splits will add large upstream projects under `third_party/<name>`, some of them GPL or LGPL. The following must stay true:

- **Credits in the same commit.** The commit that adds a submodule at `third_party/<name>` also adds its entry in `third_party/credits.toml` and any new license texts in `licenses/`. CI enforces this with `credits.py check`.
- **Shipped notices.** `THIRD_PARTY_NOTICES.md` is generated from the manifest and committed. Section 10 ships it inside the deb at `var/jb/usr/share/doc/com.getboolean.eikon/`, next to `LICENSE`. The Sileo depiction links to it at the release tag.
- **Corresponding source.** For GPL and LGPL parts, the notices say where the corresponding source is published: the eikon release tag, plus the pinned submodule commits.
- **In-app credits.** The app bundles an acknowledgements JSON. Split 02 renders it on a credits screen. Here it is only produced and bundled.

Files that already exist from earlier sections:

- `LICENSE`: the GPL-3.0 text (section 01)
- `licenses/`: license texts named `<SPDX-id>.txt`; `licenses/GPL-3.0-or-later.txt` exists from the start (section 01)
- `third_party/README.md`: the submodule convention (section 03)
- `App/Resources/Acknowledgements.json`: a checked-in placeholder containing `[]` (section 02)
- the `Makefile`, `pyproject.toml`, `.python-version` (3.12) and the `tests/` pytest scaffold (section 01)

Section 01's `make check` skips the credits step while `scripts/credits.py` doesn't exist. Section 02's `make project` depends only on `make version`, and its CI scripts job leaves out the credits check. This section removes those temporary gaps.

### Rules that apply here

- Python scripts run through `uv run` on Python 3.12 and use only the standard library. That includes `tomllib` for TOML and `subprocess` for git.
- No Python runs inside Xcode build phases.
- Tests are few and behavioral. They must not assert exact file contents, constants, string texts, or internal structure.
- No program or game titles anywhere, including fixture names and test names. Use neutral names such as `libalpha` and `libbeta`.

## Dependencies

- **Section 01** (skeleton and tooling): the Makefile, uv/pytest setup, `LICENSE`, `licenses/`, and `scripts/version.sh` (used by `make generated` through `make version`).
- **Section 02** (Xcode project): `project.yml`, the `App/` target, the placeholder `App/Resources/Acknowledgements.json`, and the minimal `ci.yml`.
- **Blocks section 10** (packaging and verifier). `archive.sh` fails a Release archive if `build/generated/Acknowledgements.json` is missing, and the deb ships `THIRD_PARTY_NOTICES.md`. Both come from this section, but that check is written in section 10, not here.
- Can run in parallel with section 05.

## Files to create or modify

| Path | Action |
|---|---|
| `third_party/credits.toml` | create (a header comment describing the format; no components) |
| `scripts/credits.py` | create |
| `THIRD_PARTY_NOTICES.md` | generate with `uv run scripts/credits.py notices --write`, then commit |
| `tests/test_credits.py` | create |
| `tests/` fixture helper (for example in `tests/conftest.py` or a helper module) | create or extend |
| `Makefile` | modify the `generated`, `project` and `check` targets |
| `project.yml` | modify how the acknowledgements resource is chosen |
| `.github/workflows/ci.yml` | modify: add the credits check to the scripts job, and check out submodules |
| `README.md` | modify: short notes on crediting a component and on generating the project through `make` |

## Tests first (`tests/test_credits.py`)

Write these pytest tests before the implementation. Each test builds a throwaway git repository under pytest's `tmp_path` and runs the checker against it.

### Fixture helper

Write one helper that creates a minimal superproject:

- `git init`, with a local user name and email so commits work in CI
- a `licenses/` directory holding whatever `<SPDX-id>.txt` files the test needs, with any text
- `third_party/credits.toml`, written from a small list of entry dicts (empty by default)
- a `THIRD_PARTY_NOTICES.md` that is current, written by calling `generate_notices()` from the script under test. Never write a hand-made copy: the test must not know what the notices look like.

Write a second helper that adds a submodule:

- Create a separate upstream repo in `tmp_path` with a `LICENSE` file and one commit.
- In the superproject, run `git -c protocol.file.allow=always submodule add <upstream> third_party/<name>`. Recent git blocks local file submodules unless that flag is set.

Import the script's functions from `scripts/credits.py`, using `importlib` with a path or by putting `scripts/` on `sys.path` in `conftest.py`. For the CLI behaviour, run `uv run scripts/credits.py …` or `sys.executable scripts/credits.py …` with `cwd` set to the fixture repo, and check only the exit code.

### Tests

1. **An empty repo passes.** No submodules, an empty manifest and current notices: `check()` returns no problems, and the `check` CLI exits 0.
2. **A credited submodule passes; an uncredited one fails and names its path.** Add `third_party/libalpha` with a matching entry (`license = "MIT"`, `license_files = ["LICENSE"]`, `licenses/MIT.txt` present), regenerate the notices, and check that `check()` is empty. Then add `third_party/libbeta` with no entry. `check()` is non-empty, at least one problem contains `third_party/libbeta`, and the CLI exits non-zero. This is the spec's done criterion.
3. **A missing license file fails.** A credited submodule whose entry lists a license file that isn't in the submodule gives a non-empty `check()`.
4. **A path that escapes the repo fails.** An entry whose `path` contains `..`, and separately one whose `path` is absolute, each give a non-empty `check()`. Parametrize over the two cases.
5. **Stale notices fail, and regeneration fixes them.** From a passing credited repo, change the manifest (for example the entry's `url`) without regenerating. `check()` is non-empty. Run the CLI `notices --write`, and `check()` is empty again.

Don't compare problem texts, notice contents or JSON contents to fixed strings. The only content assertion is that a problem mentions the offending path.

## Implementation

### `third_party/credits.toml`

Start with only a comment block that documents the format, so it parses as an empty manifest. Format for later splits:

```toml
# [[component]]
# name          = "..."            # display name
# path          = "third_party/x"  # repo-relative; a .gitmodules path or a vendored directory
# url           = "https://..."    # upstream URL
# revision      = "v1.2.3"         # pinned tag/commit (informational; notices use the gitlink)
# license       = "MIT"            # SPDX expression, e.g. "LGPL-2.1-or-later"
# license_files = ["LICENSE"]      # relative to `path`
#
# [[component.nested]]             # optional sub-licensed parts that ship
# path          = "src/sub"        # relative to the component's `path`
# license       = "BSD-3-Clause"
# license_files = ["COPYING"]      # relative to the nested `path`
```

All top-level keys are required for each component. `nested` is optional, and each nested table needs `path`, `license` and `license_files`.

### `scripts/credits.py`

Standard library only. Run it as `uv run scripts/credits.py <command>`. The repo root is the current working directory. Scripts are always invoked from the root, by make, CI and the tests.

```python
def load_manifest(repo_root: Path) -> tuple[list[dict], list[str]]:
    """Parse third_party/credits.toml. Return (components, problems). A missing file or empty
    manifest gives no components. Bad TOML or a missing or ill-typed required key becomes a
    problem naming the component (by name or index), not an exception."""

def pinned_commit(repo_root: Path, path: str) -> str | None:
    """The commit recorded for a submodule at `path`, read from the index
    (`git ls-files --stage -- <path>`, mode 160000). Read the index, not HEAD, so the check
    passes in the commit that adds the submodule, before that commit exists.
    None for a vendored directory."""

def spdx_ids(expression: str) -> set[str]:
    """License and exception ids in an SPDX expression. Split on whitespace and parentheses,
    then drop the operators AND, OR and WITH. Exception ids after WITH are kept and also need a
    text in licenses/. The full SPDX grammar is not needed."""

def check(repo_root: Path) -> list[str]:
    """Return a list of problems; an empty list means pass. Each problem is one line naming
    the offending path or id. Reports:
    - a submodule path in .gitmodules, or a directory directly under third_party/, with no
      entry (files such as README.md and credits.toml are ignored);
    - an entry whose path is absolute, contains '..', or does not exist;
    - a listed license file (top-level or nested) that does not exist, or a nested path that
      escapes its component;
    - an SPDX id used in any expression with no licenses/<id>.txt;
    - THIRD_PARTY_NOTICES.md differing from generate_notices() output (or missing)."""

def generate_notices(repo_root: Path) -> str:
    """Markdown. First Eikon itself: its name, GPL-3.0-or-later, the repo URL, and that the full
    text is in LICENSE. Then each component in manifest order: name, URL, pinned commit (from
    the gitlink, or the manifest revision for a vendored directory), SPDX expression, and the full
    text of each license file, including nested parts with their paths. It states where the
    corresponding source for GPL and LGPL parts is published: the eikon release tag plus the
    pinned submodule commits. With no components it says so."""

def generate_app_json(repo_root: Path, out: Path) -> None:
    """Write the acknowledgements JSON: a list with one object per component, in manifest order,
    with keys name, url, revision (the pinned commit as in the notices), license (the SPDX
    expression) and licenseText (the component's license texts, then nested ones, joined).
    With no components the list is empty. Create parent directories and write atomically
    (temporary file, then rename)."""

def main(argv: list[str]) -> int:
    """CLI:
      check               print problems one per line to stderr; exit 0 if none, else 1
      notices             print generate_notices() to stdout; exit 0
      notices --write     write THIRD_PARTY_NOTICES.md at the repo root; exit 0
      app-json <out>      write the JSON to <out>; exit 0
    Wrong usage exits 2 with a usage message. If the manifest itself has problems, notices and
    app-json print those problems and exit 1 without writing anything."""
```

Details:

- **Same output every run.** The notices and JSON must depend only on the repo contents: no timestamps, no absolute paths, no environment-dependent text, and no app version (otherwise every version bump would make the committed notices stale). Read license texts as UTF-8 and change CRLF to LF. End the files with exactly one newline. Write JSON with a fixed indent, sorted keys and `ensure_ascii=False`.
- **Reading `.gitmodules`.** Use `git config -f .gitmodules --get-regexp '\.path$'`. A missing `.gitmodules` means no submodules.
- **Path safety.** Reject absolute paths and any `..` component before touching the filesystem. Nested and license file paths are checked the same way, relative to their parent.
- **Submodules not checked out.** If a credited submodule's directory exists but is empty (not initialised), the missing license file problem should say to run `git submodule update --init`. It is still a failure.
- **Duplicate entries** for the same `path` are a problem.

### `THIRD_PARTY_NOTICES.md`

Generate it with `uv run scripts/credits.py notices --write` and commit it. With no components it contains only the Eikon entry and the statement that there are no third-party components. `make check` fails whenever it goes stale. The fix is always to regenerate it, never to hand-edit it.

### Makefile

- `generated`: depends on `version`, then runs `uv run scripts/credits.py app-json build/generated/Acknowledgements.json`.
- `project`: now depends on `generated` instead of `version`. It chooses the acknowledgements file (the generated one if `build/generated/Acknowledgements.json` exists, otherwise `App/Resources/Acknowledgements.json`) and runs `xcodegen generate` with `EIKON_ACKNOWLEDGEMENTS_JSON` set to that path.
- `check`: runs `uv run scripts/credits.py check` and `scripts/version.sh --check`. Remove section 01's skip for a missing `credits.py`.
- `test-scripts` (`uv run pytest tests/`) picks up the new tests automatically.

### `project.yml` (acknowledgements wiring)

The app target bundles exactly one file named `Acknowledgements.json`. XcodeGen chooses the path when it generates the project:

- Exclude `Resources/Acknowledgements.json` from the `App` sources entry, so the placeholder isn't picked up automatically as well and two resources with the same name don't collide.
- Add a separate source entry `path: ${EIKON_ACKNOWLEDGEMENTS_JSON}` with `buildPhase: resources`. XcodeGen expands environment variables in the spec.
- Generating the project through `make project` is the supported path, and the README says so. Running `xcodegen generate` without that variable is not supported.
- Confirm by building: after `make project`, the built `.app` contains `Acknowledgements.json` at its root. Check this once by hand (for example with `make test-swift` and a look in the app bundle); it is not a test.
- Section 10's `archive.sh` makes a Release build without the generated file an error. Don't add that here.

### CI (`.github/workflows/ci.yml`)

- In the `scripts` job, add a `uv run scripts/credits.py check` step after pytest.
- Set `submodules: true` on the checkout in both jobs, alongside the existing `fetch-depth: 0`, so the license file check works once real submodules land. Keep actions pinned by SHA and permissions read-only.

### README

Add a short "Adding a third-party component" note next to the build instructions: add the submodule, add its `credits.toml` entry and any missing `licenses/<id>.txt`, run `uv run scripts/credits.py notices --write`, and commit all of it together. `make check` must pass. Also say that the Xcode project is generated with `make project`.

## Done when

- `uv run pytest tests/` passes, including the five credits tests.
- `make check` passes on the repo, and `THIRD_PARTY_NOTICES.md` is committed and current.
- `make generated` writes `build/generated/Acknowledgements.json` (an empty list in 01), and `make project` followed by a build bundles exactly one `Acknowledgements.json`.
- The CI scripts job runs the credits check.
