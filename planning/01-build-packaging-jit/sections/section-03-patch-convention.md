# Section 03: Third-party libraries from fork releases

(Originally "Submodule and patch convention". On 2026-09-27 the owner changed the design twice: first "avoid submodules, they are a pain to work with", then "use releases to distribute the libraries instead of pinning to a commit". The first implementation, commit `60d29c9`, was replaced by the one described here.)

## Overview

Eikon will later link several upstream projects (FEX, Wine, Box64, Kirikiroid2) built for iOS. Split 01 has none yet. This section sets up the convention later splits follow, and the tool that manages it:

- Each upstream is a **fork** on the owner's GitHub. Eikon's changes are commits on the fork's `eikon` branch, and the fork is cloned next to this repo for development.
- The fork **builds its library and publishes it as a GitHub release**. The release tag records the fork commit, keeps it reachable after rebases, and serves as the GPL corresponding source.
- Eikon **doesn't build upstream source**. `third_party/deps.toml` pins each release asset by fork, tag, asset name and SHA-256. The build downloads it into `build/deps/<name>/`.

Forking and publishing releases are outward-facing steps, so the owner does them, or approves them, when a later split needs an upstream.

## Deliverables (as built)

- **`third_party/README.md`:** the convention, the manifest schema, the commands, the release workflow, credits in the same commit, and notes for building the libraries in the forks (the original cross-compile notes, plus nested submodules in forks such as FEX).
- **`third_party/deps.toml`:** the manifest. It is empty in split 01 and documents its schema in comments.
- **`scripts/deps.py`:** standard library only, run through `uv run`.

  | Command | What it does |
  |---|---|
  | `check` | Validates the manifest, with no network access. Required keys are `name` (lowercase), `repo` (`owner/repo`), `tag`, `asset` and a 64-hex `sha256`. `upstream` is optional. Names must be unique. Unknown keys and non-table entries are rejected. |
  | `fetch [names]` | Downloads `https://github.com/<repo>/releases/download/<tag>/<asset>`, with `$EIKON_RELEASES_URL` replacing the base if set. It caches the asset by hash in `build/deps/.cache/` and refuses a hash mismatch or a truncated download, naming the dependency. It unpacks `.tar.*` (gz, xz, bz2) with tarfile's `data` filter, `.zip` with path checks, or copies a single file. Unpacking happens in a staging directory. The swap removes the old stamp, moves the old tree aside, renames staging into place, and only then writes the stamp (`build/deps/.stamps/<name>`, holding the pin and every file's SHA-256), so an interrupted swap never verifies. A dependency that already matches its pin is skipped. Fetching everything also removes directories no manifest entry owns. |
  | `verify [names]` | Every dependency matches its pin, with every file's hash unchanged since unpacking, and `build/deps/` holds nothing outside the manifest. |
  | `pin NAME --tag TAG [--asset A]` | Downloads the release asset into the cache and rewrites that entry's `tag`, `asset` and `sha256`. It refuses a pinned tag whose asset has changed, because a pinned release must never be replaced. Before writing, it checks with tomllib that every other value is unchanged, then writes atomically, keeping line endings. |

  Archive, network and filesystem errors become one-line errors naming the dependency.
- **`Makefile`:**
  - `fetch-deps`, `verify-deps` and `pin-dep NAME= TAG= [ASSET=]` replace the `apply-patches` and `unpatch` stubs.
  - `check` also runs `deps.py check`.
- **CI:** the `scripts` job runs `deps.py check`.
- **`tests/test_deps.py`:** five behavioural tests (six cases) against a local `file://` release root.
  1. `fetch` unpacks the pinned asset, `verify` passes, and a second `fetch` leaves the same tree. Editing an unpacked file fails `verify`. A valid manifest passes `check`.
  2. A release asset replaced after pinning is rejected, naming the dependency. Nothing is unpacked, and `verify` fails.
  3. An archive member that escapes the tree is rejected, nothing is unpacked, and nothing is written outside the tree.
  4. `pin` records a new tag's hash, and `fetch` then unpacks the new asset.
  5. `check` rejects a short hash and a duplicate name.

## Rules for later splits

- A published release is never replaced once an Eikon commit pins it. Publish a new tag instead.
- Builds that link a dependency run `make verify-deps` first.
- The commit that adds a manifest entry also adds its credits entry and license texts (section 04). CI enforces this.

## Done when

- `make test-scripts` passes: 9 tests (3 version, 6 deps).
- `make check`, `fetch-deps` and `verify-deps` succeed as no-ops in the real repo. `pin-dep` without `NAME` and `TAG` prints its usage and fails.

The review trail is in `../implementation/code_review/section-03-*.md`. The first review covers the replaced submodule tool.
