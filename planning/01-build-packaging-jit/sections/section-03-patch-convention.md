# Section 03: Submodule and patch convention

## Overview

Eikon will later build several upstream projects (as git submodules) for iOS. This section sets up the convention those later splits follow, and the tool that applies local patches to them. In split 01 there are **no submodules and no patches yet**. The deliverables are the convention document, the patch tool, two Makefile targets, and a small behavioral pytest suite that proves the tool works against a throwaway fixture repo.

Deliverables:

- `third_party/README.md`: the submodule and patch convention, plus notes for later cross-compiles.
- `patches/.gitkeep`: keeps the (empty) `patches/` directory in git.
- `scripts/apply_patches.py`: applies patches with `git apply` only, and restores submodules to their pins.
- `Makefile`: real `apply-patches` and `unpatch` targets (replacing the stubs from section 01).
- `tests/test_apply_patches.py`: pytest tests with fixture submodules.

## Dependencies

- **Requires section-01-skeleton-tooling:** the `Makefile` (with stub `apply-patches` / `unpatch` targets), `pyproject.toml` with pytest run through `uv`, `.python-version`, and the `tests/` scaffold (including any shared temporary-git-repo helper in `tests/conftest.py`; reuse it if it fits, otherwise keep helpers local to this test file).
- **Blocks:** nothing. It can be done in parallel with section-02-xcode-project.
- Section 04 (credits) is related through the rule "the commit that adds a submodule adds its credits entry", but nothing here depends on it.

## Cross-cutting rules that apply here

- Tests are few and behavioral. They check what the tool does to a real git tree. They never assert the exact wording of error messages, the contents of the README, constants, or internal structure. Where a test checks that an error "names the component and the patch", it searches the output for the fixture's own component name and patch filename, which the test itself chose.
- No program or game titles anywhere, including fixture names. Use neutral names such as `libdemo` and `0001-change-greeting.patch`.
- Python scripts run via `uv run` and use only the standard library (plus pytest for tests).

---

## Tests first

File: `tests/test_apply_patches.py`. Run with `make test-scripts` (`uv run pytest tests/`).

### Fixture

Build, in a pytest `tmp_path`:

1. An **upstream repo** with a couple of committed text files. Record the commit SHA; this is the pin.
2. A **superproject repo** that adds the upstream as a submodule at `third_party/<name>` (for example `third_party/libdemo`), with `.gitmodules` setting `ignore = dirty`, and commits it. The gitlink records the pinned SHA.
3. A **patch directory** `patches/<name>/` in the superproject holding one or two patches made with `git format-patch` against the pinned commit (make a temporary commit in a scratch clone of the upstream, run `format-patch`, and copy the files in). Name them `0001-…patch`, `0002-…patch` so lexical order matters.
4. Optionally, a second upstream commit after the pin, so a test can prove the tool uses the gitlink rather than the upstream's newest commit.

Practical notes:

- Recent git refuses local-path submodule clones by default. The **tests** pass `-c protocol.file.allow=always` (or set `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` in the environment used to run the script). The script itself must not hard-code this setting.
- Set a fixed `user.name`/`user.email` in the fixture repos (via `-c` or env) so commits work on machines and CI runners with no global git identity.
- Invoke the script as a subprocess (`uv run scripts/apply_patches.py …` or `sys.executable scripts/apply_patches.py …`) with `--repo-root <fixture superproject>`, so the test goes through the real command-line interface.

### Tests

Keep to these four:

1. **Apply changes the tree and is idempotent.** After `apply`, the submodule's working tree reflects the patches (compare the patched file against what the fixture patch was built from, e.g. read it back from the scratch clone, rather than a hard-coded string). Running `apply` a second time succeeds and leaves an identical tree (compare a snapshot of file contents, or `git -C <sub> diff` output, before and after).
2. **The superproject records no new submodule commit.** After `apply`, the submodule's `HEAD` still equals the gitlink SHA (`git ls-tree HEAD third_party/<name>`), and `git status --porcelain` / `git diff --submodule` in the superproject shows no "new commits" for that submodule.
3. **A conflicting patch fails cleanly.** Add a patch that cannot apply at the pin (it targets content that doesn't exist). `apply` exits non-zero; its combined output contains the component name and that patch's filename; afterwards the submodule is at its pinned commit with a clean working tree (`git -C <sub> status --porcelain` empty, `HEAD` equals the pin). Earlier patches in the same component must not be left half-applied.
4. **Restore returns to the pin.** After a successful `apply`, `restore` leaves the submodule at its pinned commit with a clean working tree.

Not tested: README contents, exact messages, the Makefile wiring (exercised by running `make apply-patches` / `make unpatch` once by hand).

---

## Implementation

### 1. `third_party/README.md`

Write the convention as a short document for future contributors. It must cover:

**Location and pinning**
- Every upstream is a git submodule at `third_party/<name>`, pinned to a tag or commit.
- `.gitmodules` sets `ignore = dirty` for every submodule, so applied (uncommitted) patches don't show as changes in the superproject.

**Patches**
- Local changes to an upstream live **only** as `patches/<name>/NNNN-short-description.patch`, where `<name>` matches the submodule directory name and `NNNN` is a zero-padded sequence number.
- Create them with `git format-patch` against the pinned revision (commit in the submodule temporarily, export, then reset).
- They apply in lexical order **with `git apply` (working tree only)**. The submodule's `HEAD` never moves and the superproject never records a patched commit. Never commit inside a submodule and never bump a gitlink to a patched commit.
- `make apply-patches` applies them; `make unpatch` resets every submodule to its pin with a clean tree. Both accept component names via `uv run scripts/apply_patches.py apply|restore [names…]`.
- When bumping a pin, regenerate or refresh the component's patches against the new revision in the same commit.

**Out-of-tree builds**
- Upstream builds must build **out of tree**, under `build/`. Resetting a submodule runs a full clean of its working tree, which deletes anything built inside it.

**Credits in the same commit**
- The commit that adds a submodule must also add its credits entry in `third_party/credits.toml` and its license texts under `licenses/` (the credits pipeline is a separate section). CI enforces this.

**Notes for later splits (cross-compiling for iOS)**
- Cross-compile flags: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"` with `-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`.
- Per build system: CMake `CMAKE_SYSTEM_NAME=iOS`; autotools `--host=aarch64-apple-darwin`; meson cross file with `subsystem='ios'`.
- Set `ac_cv_func_pipe2=no` for the iOS 27 SDK.
- Keg-only Homebrew `bison` and `flex` must be put on `PATH` explicitly.
- llvm-mingw is the host toolchain for Wine's PE side.
- Dynamic libraries go in `Frameworks/<name>.framework` with `@rpath` install names.
- CI caches are keyed on the dependency build scripts, `patches/**`, and submodule SHAs.

### 2. `patches/.gitkeep`

Git doesn't track empty directories. Add an empty `patches/.gitkeep` so the directory exists in split 01.

### 3. `scripts/apply_patches.py`

Standard library only. Run as:

```
uv run scripts/apply_patches.py [--repo-root PATH] apply   [names…]
uv run scripts/apply_patches.py [--repo-root PATH] restore [names…]
```

`--repo-root` defaults to the superproject root (the git top-level containing the script, or the current directory's top-level). It exists so tests can point the script at a fixture repo.

Signatures (from the plan):

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

Behaviour:

- **Discovering submodules.** Read the submodule paths from `.gitmodules` (`git config -f .gitmodules --get-regexp '^submodule\..*\.path$'`). The component name is the last path component under `third_party/`. A missing `.gitmodules` means "no submodules": both commands succeed and do nothing (this is the state in split 01).
- **Pinned commit.** Always from the superproject's gitlink: `git ls-tree HEAD <path>` (the entry of type `commit`). Never from the submodule's current `HEAD` or the upstream's branch tip.
- **Reset to pin** (shared by apply and restore): if the submodule isn't initialised, run `git submodule update --init -- <path>`. Then, inside the submodule, check out the pinned commit detached (`git checkout --detach <sha>`, fetching first only if the commit is missing), `git reset --hard <sha>`, and `git clean -ffdx`. This is what makes a second `apply` start from the same base, and what makes the tool idempotent.
- **Apply.** After reset, for each `patches/<name>/*.patch` sorted lexically: run `git apply --check <patch>` in the submodule, then `git apply <patch>`. On any failure, reset the submodule to its pin again, then exit non-zero with a message that names the component and the patch file, plus git's own stderr. Stop processing further components.
- **Components without a patch directory** are just reset to their pin.
- **Named components.** If names are given, operate only on those. A name that isn't a known submodule is an error (non-zero exit). When applying to all components, a `patches/<name>/` directory with no matching submodule is also an error, since it usually means a typo or a removed submodule.
- **Never** commit in a submodule, never run `git am`, never stage anything in the superproject.
- Exit code 0 on success, non-zero on any failure; errors go to stderr.

### 4. Makefile

Replace the section-01 stubs:

| Target | Command |
|---|---|
| `apply-patches` | `uv run scripts/apply_patches.py apply` |
| `unpatch` | `uv run scripts/apply_patches.py restore` |

Both must succeed in split 01 as no-ops (there is no `.gitmodules`). Mark them `.PHONY`.

---

## Done when

- `make test-scripts` passes, including the four tests above.
- `make apply-patches` and `make unpatch` run successfully in the real repo (no submodules yet).
- `third_party/README.md` documents the convention and the cross-compile notes above.
- `patches/` exists in git via `patches/.gitkeep`.
