# Section 12: Release workflow, device runbook, and first release

## Purpose

This section finishes split 01. It covers three things:

1. **`.github/workflows/release.yml`**, the canonical publisher. On a `v*` tag it builds, creates the GitHub Release, and publishes the Sileo index to `getBoolean/eikon-source`.
2. **`device-reports/README.md`**, the device verification runbook for the two test devices, and how reports are filed.
3. **The first release, `v0.1.0`.** This means setting up the `eikon-source` environment and deploy key, tagging, the first publish (which migrates `eikon-source`), enabling Pages, running the runbook on devices, and filing the reports.

Most of the work here is outward-facing: tags, pushes, releases, repo settings, Pages, and secrets. **Every one of these is an owner-approval-gated step.** The implementer prepares the exact command or change, shows it to the owner, and runs it only after the owner explicitly approves. Nothing outward-facing runs automatically as a side effect of another step.

## Dependencies (must be complete first)

- **section-09-status-ui**: the status screen with Copy report and Share report, and the JIT section with Retry JIT. The runbook relies on these.
- **section-10-packaging-verifier**: `make all` produces and verifies `dist/Eikon-<v>.ipa`, `dist/Eikon-<v>.tipa`, `dist/com.getboolean.eikon_<v>_iphoneos-arm64.deb`, and `dist/SHA256SUMS`. `ci.yml` already builds, packages and verifies.
- **section-11-repo-publishing**: `scripts/repo/build_index.py` (it owns `docs/` wholesale and takes the deb, the asset URL, the output `docs/` directory, templates, and an icon), `packaging/repo/` templates, `scripts/repo/publish.sh` (local fallback with `--dry-run`), and the README's one-time setup steps.
- Also used from earlier sections: `scripts/version.sh --check-tag <tag>` (section 01), `scripts/file_device_report.py` and `device-reports/schema.json` (section 08), and the `Makefile` targets `all`, `check`, `test`, `archive`, `package`, `verify` (section 01).

Don't re-implement any of these. This section only wires them together and runs them.

## Cross-cutting rules that apply here

- **Tests stay few and behavioral.** Never assert exact file contents, constants, or string texts.
- **No program or game titles anywhere**: workflows, the runbook, device reports, report notes, release notes, commit messages. `/Volumes/Games` is not used.
- **Owner approval first** for anything outward-facing: pushes, tags, releases, repo settings, environments, secrets, Pages, repo description.
- **Release assets are never replaced.** A fix means a new version. Replacing an asset changes its hashes and breaks Sileo's cached index.
- Actions in workflows are pinned by commit SHA. Top-level `permissions: contents: read`. Checkout uses `fetch-depth: 0` (`version.sh` fails on a shallow clone).

---

## Tests

There are no new automated tests in this section (owner's rule: few, behavioral).

- **`release.yml`** is proven by the real `v0.1.0` release run. There is no workflow unit test.
- **Device behaviour** is proven by the filed device reports listed in the runbook. The filer's own tests belong to section 08.
- **`publish.sh --dry-run`** is exercised by hand before the first real publish. It isn't an automated test.

Checks to perform while doing this section. These are not kept as tests.

1. Before tagging, run `make all` locally on a clean tree at the commit to be tagged, and confirm it passes.
2. Run `scripts/version.sh --check-tag v0.1.0` locally. It passes with `VERSION` = `0.1.0`, and a mismatched tag such as `v0.1.1` fails.
3. Run `scripts/repo/publish.sh --dry-run` and read what it would do. It must print each outward-facing action and perform none.
4. After the release run, confirm three things. The release has the three artifacts plus `SHA256SUMS`. The `eikon-source` `docs/Packages` hash matches the deb downloaded from the asset URL. The Sileo URL serves `Release` and `Packages`.

---

## Part A: `.github/workflows/release.yml`

**Trigger:** `push` of tags matching `v*` only. There are no branch or `pull_request` triggers, and no `workflow_dispatch`.

**Top level:**
- `permissions: contents: read`, widened per job only where needed.
- `concurrency: publish`, so two tags can't race on `eikon-source`. Don't cancel in-progress runs; let them queue.
- All actions pinned by full commit SHA, with a trailing comment naming the version.

### Job `build` (macOS runner)

- `runs-on: macos-latest`. Select the newest installed Xcode through `DEVELOPER_DIR`, as `ci.yml` does, since the runner's default Xcode may lag.
- Steps:
  1. Checkout with `fetch-depth: 0`.
  2. `brew install xcodegen ldid-procursus dpkg uv` (the same tool set as `ci.yml`).
  3. **Tag guard:** `scripts/version.sh --check-tag "$GITHUB_REF_NAME"`. This fails the whole release if the tag doesn't equal `v$(cat VERSION)`.
  4. `make all` (check, test, archive, package, verify).
  5. Upload `dist/` as a workflow artifact for the next job.

### Job `release` (needs `build`)

- `runs-on: ubuntu-latest` is fine; it only needs `gh`.
- `permissions: contents: write`, on this job only.
- Steps:
  1. Download the `dist/` workflow artifact.
  2. `gh release create "$GITHUB_REF_NAME"` with the ipa, tipa, deb, and `SHA256SUMS` attached, using `GH_TOKEN: ${{ github.token }}`.
  3. **It must fail if a release for the tag already exists.** `gh release create` errors on an existing release. Don't add `--clobber`, and never use `gh release upload --clobber`. Do not "update" or delete an existing release.
- Release notes: short and honest about the prototype's state, with no program titles. Mention that the `.tipa` requires Developer Mode on iOS 16+.

### Job `publish` (needs `release`)

- `runs-on: ubuntu-latest`.
- `environment: eikon-source`. This environment has the owner as required reviewer, so every publish waits for owner approval in the GitHub UI. That is the approval gate for CI publishing.
- `permissions: contents: read`. The push to `eikon-source` uses the deploy key, not `GITHUB_TOKEN`.
- Steps:
  1. **Secret presence check.** Job-level `if:` can't read secrets, so a step does it. Pass the secret through `env` (for example `DEPLOY_KEY: ${{ secrets.EIKON_SOURCE_DEPLOY_KEY }}`), test whether it is empty, and write a step output such as `present=true|false`. If it is absent, print a clear message that says publishing was skipped because the deploy key isn't configured, and that `scripts/repo/publish.sh` is the local fallback. Then exit successfully. Every later step is conditioned on `present == 'true'`.
  2. **Download the deb from the release asset URL**:
     `https://github.com/getBoolean/eikon/releases/download/<tag>/com.getboolean.eikon_<ver>_iphoneos-arm64.deb`.
     Follow redirects. Don't use the workflow artifact copy. The index must hash exactly the bytes Sileo will download.
  3. Check out the `eikon` repo (for `scripts/repo/build_index.py`, `packaging/repo/`, and the icon) and `getBoolean/eikon-source` into a separate path, using the SSH deploy key (`ssh-key:` input of the checkout action).
  4. Set up uv, then run `uv run scripts/repo/build_index.py` with the downloaded deb, the asset URL (absolute `Filename` mode), `<eikon-source>/docs` as output, the templates, and the icon. Also render `README.md` from `packaging/repo/README.md.in` as section 11 defines.
  5. Commit as a bot identity (for example `github-actions[bot]` with its noreply email), with the message `Publish com.getboolean.eikon <ver>`, and push to `main`. If nothing changed, skip the commit and succeed.

### Stub shape (for orientation only; not a full implementation)

```yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: read
concurrency:
  group: publish
  cancel-in-progress: false
jobs:
  build:     # macos-latest; version.sh --check-tag; make all; upload dist/
  release:   # needs: build; permissions: contents: write; gh release create (fails if it exists)
  publish:   # needs: release; environment: eikon-source; secret check step; download asset; build_index; push
```

---

## Part B: `device-reports/README.md` (the runbook)

Write this file as the runbook. It holds the content below, adapted into clear numbered steps. `<v>` is the released version. All artifacts come from the GitHub Release, not local builds, so the reports describe what users get.

Add a short opening: what a device report is, that it never includes the device name, UDID, serial number, or anything about games, and that notes added before filing must follow the same rule (no program titles).

### iPad Pro 12.9" 6th gen (M2), iPadOS 17.0

**TrollStore**
1. With Developer Mode on, install `Eikon-<v>.tipa` and launch.
2. Expect TrollStore to open and return, then the status screen to show **usable** with source `trollStore`.
3. File the report.
4. Disable TrollStore's URL scheme, then relaunch after the cooldown. Expect not usable with reason `trollStoreTimedOut`. Re-enable the scheme, press **Retry JIT**, and expect usable.
5. Turn Developer Mode off and try to launch. Record what happens in the report notes: a TrollStore install warning, a launch refusal, or a launch without JIT.

**Dopamine 3, if it supports this device**
1. Uninstall the `.tipa`. Both use the same bundle id.
2. Add `https://getboolean.github.io/eikon-source/` in Sileo, install Eikon, and launch.
3. Expect usable at first paint with source `dopamine`.
4. File the report. Its notes should also answer these open questions:
   - where the data and home directories ended up
   - whether Sileo followed the GitHub release-asset redirect
   - whether `uicache` in `postinst` worked as root, or needs to run as `mobile`
5. Turn "Allow JIT in Apps" off in Dopamine and relaunch. Expect not usable with reason `dopamineJITOff`. File this report too.

If Dopamine 3 can't be used on this device, write that down. The deb is then desktop-verified only, and that is recorded.

**Debug loop (optional).** An Xcode-debugged run on the device exercises the real functional probe. It follows the debug-loop note in the top-level README.

### iPhone 13 mini (A15), iOS 27.0

**AltStore**
1. Install `Eikon-<v>.ipa` with AltStore.
2. Record any capability errors for `increased-memory-limit` or `extended-virtual-addressing`, and whether the install succeeds.
3. Launch. Expect **not usable, reason `txmEnforced`**, with or without an external JIT enabler. This device has Apple's Trusted Execution Monitor.
4. File the report.

### Filing
- Export the report from the app with **Share report** (or **Copy report** and paste to a file).
- Run `uv run scripts/file_device_report.py <path>` (or `-` for stdin). It validates the report, rejects unknown schema versions, and writes `device-reports/<date>-<model>-<method>-<hash>.json`. Refiling an identical report is a no-op.
- Commit the filed reports. Pushing them is an outward-facing action, so ask the owner first.

### What each report is expected to show (summary table for the README)

| Device | Install | Expected JIT | Source or reason |
|---|---|---|---|
| iPad M2, 17.0 | TrollStore | usable | `trollStore` |
| iPad M2, 17.0 | TrollStore, scheme disabled | not usable | `trollStoreTimedOut` |
| iPad M2, 17.0 | Dopamine 3 | usable | `dopamine` |
| iPad M2, 17.0 | Dopamine 3, JIT off | not usable | `dopamineJITOff` |
| iPhone A15, 27.0 | AltStore | not usable | `txmEnforced` |

---

## Part C: First release `v0.1.0` and one-time setup

Do these in order. **Each step marked [APPROVAL] is outward-facing.** Prepare the exact command, show it to the owner, and wait for an explicit yes before running it. If the owner declines or wants changes, stop and adjust. Don't find workarounds.

### C1. Local readiness (no approval needed)
1. `make doctor` passes.
2. `VERSION` is `0.1.0`.
3. The working tree is clean. `make all` passes locally, and `dist/` verifies.
4. `ci.yml` is green on the commit to be tagged.
5. `scripts/repo/publish.sh --dry-run` prints the plan without doing anything.

### C2. Environment and deploy key
1. **[APPROVAL]** Generate an SSH key pair locally, in `build/` or a temp directory, never committed. Add the public key to `getBoolean/eikon-source` as a deploy key **with write access**.
2. **[APPROVAL]** In `getBoolean/eikon`, create a GitHub Environment named `eikon-source` with the owner as required reviewer.
3. **[APPROVAL]** Store the private key as the environment secret `EIKON_SOURCE_DEPLOY_KEY`. The owner may prefer to paste it themselves. Offer that option.
4. Delete the local private key file after it is stored.

### C3. Inspect `eikon-source` before the first publish
1. Clone or list `getBoolean/eikon-source` read-only. Record what exists today. It is expected to have an old index with a phantom `1.0.0` entry whose deb was never uploaded.
2. The first publish replaces everything under `docs/` and rewrites `README.md`. If any **other** files exist outside `docs/` and `README.md`, list them and **[APPROVAL]** ask the owner before anything deletes them. Don't delete unexpected files without approval.

### C4. Commit and push `release.yml`
1. **[APPROVAL]** Commit `release.yml` and `device-reports/README.md`, and push to `main`. Wait for `ci.yml` to pass.

### C5. Tag and release
1. **[APPROVAL]** Create the annotated tag `v0.1.0` on the verified commit, then push the tag. This starts `release.yml`.
2. Watch the run. `build` must pass the tag guard and `make all`. `release` creates the GitHub Release with the three artifacts and `SHA256SUMS`.
3. **[APPROVAL]** The `publish` job pauses for environment approval. The owner approves it in GitHub. This migrates `eikon-source`: `docs/` is regenerated with only `0.1.0`, and `README.md` is rewritten.
4. If `publish` fails or is skipped (no secret), don't re-tag and don't touch the release. Fix the cause and re-run only the `publish` job, or fall back to `scripts/repo/publish.sh` (itself **[APPROVAL]**). The script refuses when the release already exists, so for this recovery use only its index-and-push part, as section 11 defines.
5. If the release itself is wrong, **never replace assets**. Bump `VERSION` (for example `0.1.1`), commit, and release again. Each of those steps is also **[APPROVAL]**.

### C6. Pages and repo description
1. **[APPROVAL]** Enable Pages after the first publish has put the files in place:
   `gh api -X POST repos/getBoolean/eikon-source/pages -f 'source[branch]=main' -f 'source[path]=/docs'`
   If Pages already exists, use `-X PUT` on the same endpoint instead.
2. Confirm that `https://getboolean.github.io/eikon-source/Release` and `.../Packages` load, and that the `Packages` `SHA256` matches the deb from the release asset URL.
3. **[APPROVAL]** Update the `eikon-source` repo description. Keep it short: a Sileo repo for Eikon, package index only.

### C7. Device runbook and filing
1. Run Part B on both devices, using the released artifacts. The owner does the on-device steps; the implementer guides and records.
2. File each report with `uv run scripts/file_device_report.py`, and commit them.
3. **[APPROVAL]** Push the report commit.
4. Act on what the reports show. Each follow-up that lands a change goes through normal review, and any new release is a new version:
   - **Sileo didn't follow the redirect.** Switch `build_index.py` to `filename_mode="relative"` with the deb committed under `docs/debs/` while it's under 100 MB. That is a new publish, so **[APPROVAL]**.
   - **AltStore rejected a capability.** Drop that key from `packaging/entitlements/ipa.plist`, and note it in `packaging/entitlements/README.md`.
   - **`uicache` needs `mobile`.** Adjust `postinst` and `prerm`.
   - **Dopamine 3 unsupported on the iPad.** Record the deb as desktop-verified only.
   - **The TXM table was wrong for a CPU family.** Correct the table, which is keyed by CPU family.

---

## Files created or modified

- `.github/workflows/release.yml` (new)
- `device-reports/README.md` (new; the runbook and filing instructions)
- `device-reports/*.json` (new; filed reports, produced by the filer)
- Possibly, depending on report outcomes: `packaging/entitlements/ipa.plist`, `packaging/entitlements/README.md`, `packaging/deb/postinst`, `packaging/deb/prerm`, and the TXM CPU-family table. These are follow-ups, not part of the initial work.

External state changed only with owner approval: the `eikon-source` deploy key, the `eikon-source` environment and its secret on `eikon`, the `v0.1.0` tag and GitHub Release, the `eikon-source` `main` branch, Pages settings, and the repo description.

## Done when

- `release.yml` exists. On the `v0.1.0` tag it passed the tag guard, built and verified, created the release (and would fail on an existing one), and published the index after environment approval.
- `https://getboolean.github.io/eikon-source/` serves a valid index with only `0.1.0`, and its hashes match the release asset.
- `device-reports/README.md` holds the runbook. Reports for each runbook case that could be run are filed and committed, and any case that couldn't be run is recorded as such.
- Every outward-facing action was taken only after explicit owner approval.

---

## Implementation notes (as built)

Local deliverables (done):
- `.github/workflows/release.yml`: on a `v*` tag, the `build` job runs the tag guard (`version.sh --check-tag`) then `make all` and uploads `dist/`; the `release` job creates the GitHub Release from the artifacts and fails if it already exists (no `--clobber`); the `publish` job is gated on the `eikon-source` environment, skips cleanly when the deploy key is absent, downloads the deb from the release asset URL, verifies it against the release's `SHA256SUMS`, rebuilds the index and pushes to `eikon-source` with the deploy key. Actions are SHA-pinned; top-level permissions are read-only.
- `device-reports/README.md`: the runbook for the iPad (TrollStore, Dopamine 3) and the iPhone (AltStore, TXM), the filing steps, the expected-results table, and the follow-ups. No titles; the privacy rule is stated.

Local checks passed: `make all` on a clean tree (25 script tests); `version.sh --check-tag v0.1.0` passes and `v0.1.1` fails; `release.yml` parses with the expected structure. The review added the `SHA256SUMS` verification in the publish job.

**Part C is not done here.** Every step is outward-facing (the deploy key, the `eikon-source` environment and secret, the `v0.1.0` tag and release, the environment-approved publish, enabling Pages, the repo description, running the device runbook and pushing the reports). Each needs explicit owner approval and is presented to the owner, not run automatically.

The review trail is in `../implementation/code_review/section-12-*.md`.
