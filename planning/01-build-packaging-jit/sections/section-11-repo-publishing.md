# Section 11: Publishing to the `eikon-source` Sileo repo

## Goal

Publish the Dopamine rootless deb to the Sileo repo at `https://getboolean.github.io/eikon-source/`. GitHub Pages serves that repo from the separate repository `getBoolean/eikon-source`.

This section delivers:

1. **Templates and icons** in `packaging/repo/`.
2. **`scripts/repo/build_index.py`**, which regenerates the whole `docs/` tree of `eikon-source` from one deb. It writes `Packages`, its compressed copies, `Release`, the native depiction, the landing page, the icons and `.nojekyll`.
3. **`scripts/repo/publish.sh`**, the local fallback publisher. CI is the canonical publisher, and its workflow belongs to section 12.
4. **One-time setup steps in `README.md`**: the deploy key in a protected environment, enabling Pages, and the repo description. They are documented here and **not run** here.
5. **A few behavioral pytest tests** for `build_index.py`.

Nothing in this section pushes, creates a release, changes repo settings or enables Pages. Every one of those is outward-facing. It happens in section 12, with the owner's approval first.

## Dependencies

- **Requires section 10 (packaging and verifier):**
  - `scripts/package.sh deb` produces `dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb`.
  - `make package` writes `dist/SHA256SUMS`.
  - `scripts/verify_artifacts.py dist/` verifies the artifacts.
  - The deb's control file already carries `Name`, `Author`, `Icon`, `Depiction`, `SileoDepiction`, `Homepage` and `Section`, so they reach the index through the control fields.
- **Uses from section 01:**
  - `VERSION`
  - the `Makefile`, which has a `publish` target to fill in here
  - `pyproject.toml` with pytest through `uv`
  - the `tests/` scaffold and its temp-dir helpers
  - `scripts/doctor.sh`, which already checks for `dpkg-deb`, `zstd`, `xz` and `gh`
- **Blocks section 12:**
  - `release.yml`'s publish job calls `build_index.py` with the command line defined here.
  - The first real publish, the `eikon-source` migration and enabling Pages happen there.

## Background

### Why the deb is not in `eikon-source`

- **Where debs live.** Debs are **GitHub Release assets on `getBoolean/eikon`**. `eikon-source` holds only the index and the Pages files.
  - Once FEX and Wine land, debs will pass git's 100 MB file limit.
  - Pages serves Git LFS *pointers*, not the files.
- **Absolute `Filename`.** The `Packages` stanza uses the asset URL as its `Filename`. Sileo accepts an absolute https `Filename`. Plain apt is not a target.
- **The redirect is unverified.** GitHub redirects the asset URL to object storage. Whether Sileo follows that redirect is checked on the first device install.
- **Relative mode is the fallback.** If Sileo fails there, `build_index.py` supports a relative mode. The deb is then committed under `docs/debs/` while it stays under 100 MB.

### Release policy

- **Assets are never replaced.** A fix means a new version. A re-uploaded asset changes its hashes and breaks Sileo's cached index.
- **CI is canonical.** `publish.sh` is only the fallback for when CI can't publish.
- **Index hashes come from the download.** The deb passed to `build_index.py` is **downloaded back from the asset URL**. Then the hashes in `Packages` match exactly what Sileo downloads.

### What Sileo requires of a flat repo

These rules are verified in Sileo's source.

**What it fetches**
- `Release`, then the first of `Packages.zst`, `Packages.xz`, `Packages.lzma`, `Packages.bz2`, `Packages.gz` and `Packages` that succeeds.
- `Release.gpg`. **Unsigned repos are fine.** Don't publish `Release.gpg` without a keyring package.

**`Release` requirements**
- It **must** have `Architectures:` (containing `iphoneos-arm64`) and `Components:`.
- Hash section headers need their trailing colon (`MD5Sum:`, `SHA256:`). Without it, the parser skips the section silently.
- Sileo checks SHA256 and SHA512 only, and every listed hash must match its file.

**How it reads the index**
- It filters stanzas by `Architecture`.
- A relative `Filename` resolves against the repo URL, and an absolute https `Filename` works in Sileo.
- The repo icon is `CydiaIcon.png` at the repo root.

**Native depictions**
- A depiction is a `DepictionTabView` with `minVersion` "0.4" and a `tintColor`.
- An empty `headerImage` should be omitted, not written empty.

### `eikon-source` today, and its target state

**Today**

The repo is public, its default branch is `main`, and it holds `README.md` and `docs/{Packages, Release, depiction.json, index.html}`. **Pages is not enabled.** The files that are there are broken or stale:

- `Packages` points to a `1.0.0` deb and to `icon.png`. Neither file exists.
- `Release` lists `Packages.bz2` and `Packages.gz`, which don't exist.
- `Release`'s hash headers have no trailing colon, so Sileo never checks the hashes.
- The descriptions contain outdated text. The landing page calls the repo "not a live Sileo source".

All of it is replaced on the first publish. The first version is `0.1.0`, which supersedes the phantom `1.0.0` entry.

**Target state of `main`**

```
README.md            # what the repo is, the Sileo URL, "package files only"
docs/                # owned wholesale by build_index.py
  .nojekyll  Release  Packages  Packages.xz  Packages.zst
  depiction.json  index.html  CydiaIcon.png  icon.png
  debs/<deb>         # relative mode only
```

- `eikon-source` holds no debs (except in relative mode), no scripts and no workflows.
- Pages is served from branch `main`, folder `/docs`.
- `.nojekyll` stops Jekyll processing, and no Pages workflow file is needed.

## Tests first

Write these tests in `tests/test_build_index.py` before implementing, and run them with `uv run pytest tests/`.

**Owner's rule:** the tests are few and behavioral. They check what the index does for Sileo. They must **not** assert exact file contents, template text, depiction wording, constant values or internal structure.

### Fixture

- **The deb.** Build a small deb inside the test with `dpkg-deb`:
  - a temp stage with `DEBIAN/control` holding `Package: com.getboolean.eikon`, a `Version`, `Architecture: iphoneos-arm64`, a `Name` and a one-line `Description`
  - one small payload file under `var/jb/`
  - built with `dpkg-deb --root-owner-group -b`
- **Tool guard.** Skip the module (`pytest.skip` at module level) if `shutil.which("dpkg-deb")` or `shutil.which("zstd")` is `None`. Both are present on the development Mac after bootstrap and on `ubuntu-latest`.
- **Templates and icons.** Use the real `packaging/repo/` templates and icon directory. That exercises rendering without asserting what it says.
- **Output.** Pass `out_docs` as `tmp_path / "eikon-source" / "docs"`, so the test can check that files beside `docs/` are untouched.
- **Parameterised versions.** A helper builds the deb for a given version, so the third test can build an older and a newer deb.

### Tests

1. **`Release` hashes are complete and correct.**
   - Parse `Release`.
   - For every entry under `MD5Sum:` and under `SHA256:`, the named file exists under `docs/`. Its size equals the listed size, and its MD5 or SHA-256 equals the listed hash.
   - Each section lists at least one file, including `Packages`.
   - `Release` has an `Architectures:` field whose value contains `iphoneos-arm64`, and a `Components:` field.
   - These are Sileo's hard requirements. They are checked by field presence, not by comparing text.
2. **The `Packages` stanza matches the deb, in both filename modes.**
   - Parse `Packages` (and decompress `Packages.xz` with `lzma` to check it parses to the same stanzas).
   - There is exactly one stanza.
   - Its `SHA256` and `Size` equal the fixture deb's SHA-256 and byte size, computed in the test.
   - **Absolute mode:** `Filename` equals the asset URL passed in.
   - **Relative mode:** `Filename` equals `debs/<deb file name>`, and `docs/debs/<deb file name>` exists with the same SHA-256.
   - Parameterise over the two modes.
3. **A rerun replaces everything.**
   - Run `build_index` with version A.
   - Drop a stray file into `docs/` and a sentinel file beside `docs/` (in the `eikon-source` root).
   - Run again with a newer version B.
   - `Packages` has exactly one stanza, and its `Version` is B.
   - The stray file inside `docs/` is gone. Every file under `docs/` is either listed in `Release` or is one of the non-index files the function writes. Compare the tree against the set produced by a fresh run into an empty directory, not against a hard-coded list.
   - The sentinel beside `docs/` still exists, unchanged.

`publish.sh` has **no automated test**. Its `--dry-run` is exercised by hand before the first real publish.

## Files to create or modify

```
packaging/repo/
  depiction.json.in
  index.html.in
  README.md.in
  icon/
    icon.png          # package icon (the deb's Icon: field points at docs/icon.png)
    CydiaIcon.png     # repo icon Sileo shows for the source
scripts/repo/
  build_index.py
  publish.sh          # mode 0755
tests/test_build_index.py
Makefile              # fill in the `publish` target
README.md             # add "Publishing" and "One-time setup" sections
```

## `packaging/repo/` templates and icons

### Placeholders

- **Style.** Templates use the same `@NAME@` placeholder style as `packaging/deb/control.in`.
- **Substitution.** `build_index.py` substitutes every placeholder, then fails if any `@[A-Z_]+@` token is left in the output.
- **Escaping.**
  - Values inserted into `depiction.json.in` are JSON-string escaped. After substitution, the result is parsed with `json.loads`, and the build fails if it doesn't parse.
  - Values inserted into `index.html.in` are escaped with `html.escape`.

**Placeholders to support:**

| Placeholder | Value |
|---|---|
| `@VERSION@` | the deb's `Version` control field |
| `@DATE@` | the build date (UTC, ISO `YYYY-MM-DD`) |
| `@DESCRIPTION@` | the deb's `Description` (first line, plus the extended text if any) |
| `@REPO_URL@` | `https://getboolean.github.io/eikon-source/` (trailing slash) |
| `@SOURCE_URL@` | `https://github.com/getBoolean/eikon` |
| `@RELEASE_URL@` | `https://github.com/getBoolean/eikon/releases/tag/v<ver>` |
| `@LICENSE_URL@` | `https://github.com/getBoolean/eikon/blob/v<ver>/LICENSE` |
| `@NOTICES_URL@` | `https://github.com/getBoolean/eikon/blob/v<ver>/THIRD_PARTY_NOTICES.md` |

- **Where the URLs live.** Keep the fixed URLs as module-level constants in `build_index.py`, built from one base for the Pages URL and one for the GitHub repo.
- **Deriving the tag.** The tag is always `v` followed by the deb's version.

### `depiction.json.in` (Sileo native depiction)

**Top level**
- `"class": "DepictionTabView"`, `"minVersion": "0.4"`, `"tintColor": "#c6f54a"`.
- **No `headerImage` key.**

**Details tab** (a `DepictionStackView` with `"tabname": "Details"`)
- A `DepictionMarkdownView` with `@DESCRIPTION@`, honest that the app is an early prototype. In this version it shows its install method, JIT status and a device report. Game features come later.
- `DepictionTableTextView` rows:
  - Version: `@VERSION@`
  - Released: `@DATE@`
  - Compatibility: "iOS 15.0 or later, Dopamine (rootless)"
- A markdown line saying JIT is enabled automatically on Dopamine.
- A note that the TrollStore build (`.tipa`), offered on the release page and not through this repo, needs **Developer Mode on iOS 16 and later**.
- `DepictionTableButtonView` links to the source repo (`@SOURCE_URL@`) and the release (`@RELEASE_URL@`).

**Licenses tab** (`"tabname": "Licenses"`)
- A markdown view stating the app is licensed GPL-3.0-or-later, with a button to `@LICENSE_URL@`.
- A button to the third-party notices at the tag (`@NOTICES_URL@`).

**Must not contain**
- program or game titles, or demo sketch names
- "Wine under FEX"
- "not a live source"
- claims of features that don't exist yet

### `index.html.in` (landing page at the repo URL)

A small, self-contained HTML page with inline CSS, no external requests and no JavaScript needed. It contains:

- **Heading.** The app name and a one-sentence honest description.
- **Adding the source.**
  - The repo URL `@REPO_URL@` shown as text, to add in Sileo.
  - A `sileo://source/@REPO_URL@` link.
- **Package details.** The current version `@VERSION@` and date `@DATE@`.
- **Links.** The source repo, the release, the license and the notices.
- **Other install methods.** The TrollStore `.tipa` (Developer Mode on iOS 16+) and the AltStore `.ipa` are on the GitHub release, not in this repo.

It carries the same "must not contain" rules as the depiction.

### `README.md.in` (the `eikon-source` repo's README)

- **Purpose.** This repo is the Sileo source for Eikon, served by GitHub Pages from `main` `/docs`.
- **Source URL.** It gives `@REPO_URL@`, with the trailing slash.
- **Contents.** It holds **package index files only**. Debs are GitHub Release assets on `getBoolean/eikon`.
- **Ownership.** Everything under `docs/` is generated by `scripts/repo/build_index.py` in `getBoolean/eikon`, and hand edits are overwritten.
- **Links.** The app repo and its releases.

It takes only `@REPO_URL@` and `@SOURCE_URL@`, so it doesn't change with each version.

### Icons

- **Files.**
  - `icon/icon.png` is the package icon, 512×512 PNG.
  - `icon/CydiaIcon.png` is the repo icon, 180×180 PNG.
- **Origin.** Both are resized from the original app icon made in section 02, and they are committed as they are.
- **No resizing at build time.** `build_index.py` only copies them. It runs on Ubuntu too, where `sips` doesn't exist.
- **Originality.** Both must be original art with no third-party logos.
- **The deb's `Icon:` field.** It already points to `https://getboolean.github.io/eikon-source/icon.png`, which is `docs/icon.png`.

## `scripts/repo/build_index.py`

### Runtime and interface

- **Runtime.** Python 3.12 through `uv run`, standard library only.
  - It calls `dpkg-deb` to read control fields and `zstd` to compress. Python 3.12's standard library has no zstd module.
  - `xz` compression uses the standard library `lzma` module.

**Signature** (keep this interface; section 12's workflow calls the CLI):

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

def render_repo_readme(templates: Path, dest: Path) -> None:
    """Render README.md.in to dest (the eikon-source root README). Separate from build_index
    so that build_index never writes outside out_docs."""
```

**Command line**

```
uv run scripts/repo/build_index.py \
    --deb PATH --asset-url URL --out DOCS_DIR \
    [--templates packaging/repo] [--icons packaging/repo/icon] \
    [--filename-mode absolute|relative] [--repo-readme PATH]
```

- `--templates` and `--icons` default to paths relative to the `eikon` repo root, which is found from the script's own location.
- `--repo-readme`, when given, also calls `render_repo_readme` for that path. `publish.sh` and CI pass `<eikon-source clone>/README.md`.
- **Exit codes:** 0 on success. Non-zero on any error, with a one-line message on stderr naming the problem (the missing tool, the bad field, the unparsable depiction).

### Behaviour

**1. Validate the input**
- The deb exists and `dpkg-deb -f <deb>` succeeds.
- Its control has `Package: com.getboolean.eikon` and `Architecture: iphoneos-arm64`.
- In absolute mode, `asset_url` starts with `https://` and ends with the deb's file name.
- Fail before writing anything.

**2. Read the control fields**
- `dpkg-deb -f <deb>` with no field names prints the whole control paragraph.
- Keep the fields in their original order, including multi-line `Description` continuation lines exactly as they are.

**3. Build into a staging directory**
- The staging directory is a sibling of `out_docs`: `tempfile.mkdtemp(dir=out_docs.parent)`, so the final rename stays on one filesystem.
- Create `out_docs.parent` if it's missing.

**4. Write the `Packages` stanza**
- The control fields, then:
  - `Filename:` (the asset URL, or `debs/<deb name>` in relative mode)
  - `Size:`
  - `MD5sum:`
  - `SHA1:`
  - `SHA256:`
- The field casing is the Packages convention: `MD5sum`, not `MD5Sum`.
- The stanza ends with a single blank line.
- Hashes and size are computed from the `deb` file passed in, which callers download from `asset_url`.
- In relative mode, copy the deb to `<stage>/debs/<deb name>`.

**5. Write the compressed copies**
- `Packages.xz` through `lzma.compress` (`FORMAT_XZ`).
- `Packages.zst` through `zstd -q -19 -o <out> <in>`.
- Fail clearly if `zstd` is missing.

**6. Write `Release`**
- Fields:
  - `Origin: Eikon`, `Label: Eikon`, `Suite: stable`, `Codename: ios`
  - `Version:` the package version
  - `Architectures: iphoneos-arm64`, `Components: main`
  - a short `Description:`
  - `Date:` from `email.utils.format_datetime(datetime.now(timezone.utc), usegmt=True)`
- Then an `MD5Sum:` section and a `SHA256:` section. Each is a header line with the trailing colon, followed by one line per file: ` <hash> <size> <name>`, with a leading space.
- The listed files are exactly `Packages`, `Packages.xz` and `Packages.zst`, with names relative to `docs/`.
- Don't list files that aren't written, and don't write `Release.gpg`.
- Write through a temp file and rename.

**7. Render the templates**
- Render `depiction.json` and `index.html` as described above.
- For `depiction.json`, parse it with `json.loads` and re-serialize it with `json.dumps(obj, indent=2, ensure_ascii=False)` so the output is always valid.

**8. Copy the rest**
- Copy the two icons as `icon.png` and `CydiaIcon.png`.
- Write an empty `.nojekyll`.

**9. Swap the staging directory in**
- If `out_docs` exists, rename it to a sibling backup path.
- Rename the staging directory to `out_docs`, then remove the backup.
- On any failure before the swap, remove the staging directory and leave `out_docs` as it was.
- Nothing outside `out_docs` is created, changed or removed, apart from the transient staging and backup siblings, which are always cleaned up.

**Only the latest version** is ever in the index. Version history lives in GitHub Releases on `eikon`.

### Helpers

A suggested split, each small and testable through `build_index`:

- `read_control(deb) -> list[tuple[str, str]]`
- `file_digests(path) -> dict` (size, md5, sha1, sha256)
- `packages_stanza(fields, filename, digests) -> str`
- `release_text(version, entries) -> str`
- `render(template_text, values, escape) -> str`, which raises on a leftover placeholder

## `scripts/repo/publish.sh`

This is the local fallback publisher for when CI can't publish. It is a bash script with `set -euo pipefail`, and it runs from the `eikon` repo root.

**Usage**

```
scripts/repo/publish.sh [--dry-run] [--filename-mode absolute|relative]
make publish ARGS="--dry-run"
```

**Every outward-facing action is announced.** Before each one (release creation, clone, push), the script prints the exact command it is about to run. With `--dry-run`, it prints the command and doesn't run it.

### Steps

**1. Preflight.** Fail with a clear message on the first unmet condition.
- **Clean tree:** `git status --porcelain` is empty.
- **Tag:** `VER=$(cat VERSION)`, and `HEAD` is tagged `v$VER` (`git tag --points-at HEAD` contains it). Also run `scripts/version.sh --check`.
- **Artifacts:** `dist/` holds the three artifacts for `$VER` and `SHA256SUMS`, and `uv run scripts/verify_artifacts.py dist/` passes.
- **Tools:** `gh auth status` succeeds, and `dpkg-deb` and `zstd` exist.
- **No existing release:** `gh release view "v$VER" --repo getBoolean/eikon` **fails**, meaning the release doesn't exist. If it exists, refuse and exit non-zero. This script never replaces or re-uploads assets. A fix means a new version.

**2. Create the release**
- Run `gh release create "v$VER" --repo getBoolean/eikon --title "v$VER" --notes <short notes> <ipa> <tipa> <deb> dist/SHA256SUMS`.
- The notes are short, honest, and free of any program titles.

**3. Download the deb back**
- The asset URL is `https://github.com/getBoolean/eikon/releases/download/v$VER/com.getboolean.eikon_${VER}_iphoneos-arm64.deb`.
- Download it with `curl -fL --retry 3` into `build/publish/`.
- Check that its SHA-256 equals the deb's line in `dist/SHA256SUMS`, and stop if it doesn't.
- The downloaded file, not the local `dist/` copy, is what the index hashes.

**4. Clone `eikon-source`**
- Remove any existing `build/eikon-source`, then clone the remote into it. The remote is `EIKON_SOURCE_REMOTE`, default `git@github.com:getBoolean/eikon-source.git`.
- **First-publish migration guard.** List the clone's tracked top-level entries. If anything other than `README.md` and `docs/` is present, print the list and stop. The owner decides what to delete; the script never deletes unexpected files.

**5. Build the index**
- Run `uv run scripts/repo/build_index.py`, passing:
  - `--deb <downloaded deb>`
  - `--asset-url <asset URL>`
  - `--out build/eikon-source/docs`
  - `--filename-mode <mode>`
  - `--repo-readme build/eikon-source/README.md`
- This replaces `docs/` wholesale and rewrites the README, which is what the first-publish migration needs too.

**6. Commit and push**
- In the clone: `git add -A`, then commit with the message `Publish com.getboolean.eikon $VER`, then `git push origin main`.
- Print the Sileo URL: `https://getboolean.github.io/eikon-source/`, with the trailing slash.

### `--dry-run`

- It runs every preflight check, except that an existing release is only reported, not treated as an error.
- It prints the release command without running it.
- It skips the download and uses `dist/`'s deb as a stand-in, noting that the real run hashes the downloaded asset.
- It clones read-only and builds the index into the clone. It prints `git -C build/eikon-source status --short` and `git diff --stat`, so the owner can see what would change.
- It prints the commit and push commands without running them.

`publish.sh` isn't run for real in this section. Its first real use, if any, is in section 12 and needs the owner's approval.

## Makefile

Replace section 01's `publish` stub:

```make
publish:
	scripts/repo/publish.sh $(ARGS)
```

`make all` must not depend on `publish`.

## `README.md` additions

Add a **"Publishing"** section:

- **Sources.** The Sileo source URL (with trailing slash). Debs are GitHub Release assets, and `eikon-source` holds only the index.
- **Who publishes.** CI is the canonical publisher: a `v*` tag runs `release.yml`. `make publish` (with `ARGS="--dry-run"` first) is the local fallback.
- **Release policy.** Assets are never replaced, and a fix means a new version.
- **Relative-mode fallback.** Use it if Sileo can't follow the release-asset redirect. The deb is then committed under `docs/debs/` while it is under 100 MB.

Add a **"One-time setup (owner-run or owner-approved)"** section listing these steps. They are documented only; the implementer prepares each one and asks the owner before running it (section 12).

1. **Deploy key.**
   - Generate an SSH key pair, for example `ssh-keygen -t ed25519 -N "" -f eikon-source-deploy`.
   - Add the public key as a deploy key **with write access** on `getBoolean/eikon-source`:
     `gh repo deploy-key add eikon-source-deploy.pub --repo getBoolean/eikon-source --allow-write --title "eikon publish"`
   - In `getBoolean/eikon`, create a **GitHub Environment** named `eikon-source`, with the owner as required reviewer.
   - Store the private key as the environment secret `EIKON_SOURCE_DEPLOY_KEY`:
     `gh secret set EIKON_SOURCE_DEPLOY_KEY --repo getBoolean/eikon --env eikon-source < eikon-source-deploy`
   - Delete the local key files afterwards.
2. **Pages.** After the first publish has put the files in `docs/`, enable Pages from `main` `/docs`:
   `gh api -X POST repos/getBoolean/eikon-source/pages -f 'source[branch]=main' -f 'source[path]=/docs'`
   If Pages already exists, the `POST` fails. Use the same command with `-X PUT` instead.
3. **Repo description.** Update the `eikon-source` description to say it is the Sileo source for Eikon, with package index files only:
   `gh repo edit getBoolean/eikon-source --description "..." --homepage https://getboolean.github.io/eikon-source/`

## Rules that apply here

- **No program or game titles** anywhere: templates, depiction, landing page, README, release notes, commit messages or test names.
- **Standard library only** in Python, run through `uv run`. `dpkg-deb`, `zstd`, `curl`, `git` and `gh` are called as subprocesses or from the shell script.
- **Nothing outward-facing runs in this section.** That covers pushing to either repo, creating a release, creating deploy keys, environments or secrets, enabling Pages, and editing repo settings. All of it is deferred to section 12, with owner approval first.

## Done when

- `uv run pytest tests/` passes, including the three index tests. They skip cleanly where `dpkg-deb` or `zstd` is missing.
- `uv run scripts/repo/build_index.py` run by hand against a locally built `dist/` deb produces a `docs/` tree with:
  - a `depiction.json` that parses
  - an `index.html` that renders in a browser
  - a `Release` whose hashes match
- `scripts/repo/publish.sh --dry-run` runs its preflight and prints the planned actions without changing anything remote.
- `README.md` documents publishing and the one-time setup steps.

---

## Implementation notes (as built)

Files: `packaging/repo/{depiction.json.in,index.html.in,README.md.in,icon/{icon.png,CydiaIcon.png}}`, `scripts/repo/{build_index.py,publish.sh}`, `tests/test_build_index.py`, the Makefile `publish` target, and the README Publishing / one-time-setup sections. The icons are the app icon resized to 512×512 and 180×180, opaque.

Verified: `build_index.py` run against the real `dist/` deb produces a `docs/` tree whose `depiction.json` parses, whose `index.html` renders, and whose `Release` lists Packages/Packages.xz/Packages.zst with matching hashes and sizes, with no leftover placeholders. Five pytest tests cover the Release hashes, the Packages stanza in both filename modes, a rerun replacing everything, and a failed rebuild leaving the previous docs intact. They skip without dpkg-deb or zstd. `publish.sh` preflight refuses cleanly and touches nothing.

From the code review:
- **Safe swap:** a rebuild that fails after moving the old `docs/` aside restores it, rather than losing it (the previous version was a data-loss path). Covered by the new test.
- The Packages stanza ends with a blank line; the Description is normalised for the templates only; hashing streams the deb; `MD5Sum` is documented as decorative.

Not run here (deferred to section 12, owner-approved): the first real publish, a full `publish.sh --dry-run` (it clones `eikon-source`), the `eikon-source` migration, the deploy key/environment/secret, enabling Pages, and the repo description. The README documents each.

The review trail is in `../implementation/code_review/section-11-*.md`.
