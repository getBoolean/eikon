# Eikon handoff

Eikon is an unfinished prototype. It is not a working emulator. Nothing here runs a game on a device. There is no JIT bypass, no exploit, and no commercial games.

Said “AY-kon.” From Greek *eikon*, a likeness. The name is not a jailbreak tool and not a SpringBoard tweak.

## Repos

| Role | GitHub | What it is |
|---|---|---|
| App | https://github.com/getBoolean/eikon | UIKit shell, Theos layout, FEX-Emu, Wine, and the original sketches |
| Apt files only | https://github.com/getBoolean/eikon-source | Sileo source sketch. No app source |

Package id: `com.getboolean.eikon`
Display name: Eikon
Architecture: `iphoneos-arm64`
Install root: `/var/jb` (Dopamine 2 rootless)

Intended Sileo URL, once GitHub Pages is actually serving:

https://getboolean.github.io/eikon-source

That URL returns 404. Pages is not on. Do not describe the source as live.

Do not recreate or push to these. They are gone:

- https://github.com/getBoolean/jailbreak
- https://github.com/getBoolean/sileo-source
- Origin repo `daniel-newville/eikon`

## Local trees

- App checkout: `/workspace`. Aimed at https://github.com/getBoolean/eikon. This handoff is the first file uploaded there besides the README. The rest of the app (Sources, Theos layout, submodules, demos, IPA shell) is local and has not been pushed to that GitHub repo.
- Apt checkout: `/home/ubuntu/eikon-source`. Local commit `ce678da` is the apt tree used as the source of truth for the files below. Later GitHub commits were made through the API, not by pushing that git history.
- `/home/ubuntu/sileo-source` is leftover scratch. Its GitHub remote was removed. Do not push it.

`git push` to GitHub fails here: `fatal: could not read Username for 'https://github.com'`. Do not retry `git push` or `gh auth`. Use the GitHub API, already authenticated as getBoolean.

## Engine

Linux stays on FEX. Windows follows Autorun: Wine built for ARM64, with Box64 translating only the guest program. The stage split is `plans/stages.md`.

- Linux x86-64: FEX-Emu directly. Submodule `third_party/FEX` at tag `FEX-2609`. Do not run Linux guests under Box64, QEMU, or v86.
- Windows: Wine native on ARM64. Submodule `third_party/wine` at tag `wine-11.0`. Box64 tag `v0.3.6` is the CPU backend. Wine is not run under FEX. Autorun's Horizon server and Mesa-switch drivers are not copied.
- Guest engines, with no program titles recorded: Kirikiri and BGI first, then Ren'Py and GameMaker, then Unity.
- FEX and Wine are not built into the iOS app until the stage that links them.

What was tried on a Linux machine, not on a phone:

- Signal Drift under FEX’s x86 simulator: one frame matched a native run, then FEX aborted on exit.
- Brickline ran under that machine’s own Wine, not under FEX.
- Wine under FEX has not run. That simulator build aborts on dynamic ELFs, and Wine is dynamic.

Sketches, original, not commercial: Signal Drift (`demos/linux`) and Brickline (`demos/windows`). They are not playable in the app.

## What is on eikon-source

Text files landed. Depiction, Icon, and Sileodepiction use `https://getboolean.github.io/eikon-source/`. `docs/Packages` is 825 bytes, SHA1 `5469eb948454805d60494a80d9d3e125d9141c73`, which matches `docs/Release`.

- `README.md` — https://github.com/getBoolean/eikon-source/commit/da8ef2732c9dd5279622e8e3ad5ddd63b319401d
- `docs/Packages` — https://github.com/getBoolean/eikon-source/commit/2b96fa83f65ac3d19c8637288064ce8277883560
- `docs/Release` — https://github.com/getBoolean/eikon-source/commit/0c56a73f4347b57211b5407cd1cd6ccc29544e1e
- `docs/depiction.json` — https://github.com/getBoolean/eikon-source/commit/c3d6332303e8718c73f0b2e588b5acb4b095ec1f
- `docs/index.html` — https://github.com/getBoolean/eikon-source/commit/b52a910233a1a1d2d6eb5a78c0509d12fe237514

## What is not on eikon-source

Sileo cannot install from this source yet. These files are still only on disk under `/home/ubuntu/eikon-source`:

- `docs/debs/com.getboolean.eikon_1.0.0_iphoneos-arm64.deb` (required)
- `docs/Packages.bz2`
- `docs/Packages.gz`
- `docs/icon.png`
- `.github/workflows/pages.yml`

The Contents API stores the UTF-8 of the content string. Bytes above 127 get expanded, so those binaries cannot be sent as text. Pre-base64 stores the base64 text, not the original bytes. `create_or_update_file` does the base64 step itself for text. Do not pre-base64 text. For the deb, bz2, gz, and png, base64 the raw bytes exactly once and send that as the API `content` field if the caller does not encode again.

`push_files` returned 404 from `POST /repos/getBoolean/eikon-source/git/trees`. Creating `.github/workflows/pages.yml` returned 404. The workflow is not on the repo, and Pages is not serving.

## Next

Implementation order is `plans/stages.md`. The `1.0.0` sizes below belong to a package that is not in this checkout. Stage 10 publishes the `0.1.0` shell instead of those bytes.

1. Upload the deb, `Packages.bz2`, `Packages.gz`, and `icon.png` as real bytes. The historical sizes, for the missing package, were deb 388546, bz2 565, gz 510, png 8599.
2. Put `.github/workflows/pages.yml` on `main`. It deploys `docs/` only after Pages is enabled. A 404 from the contents API means the token cannot write workflow files.
3. Turn on GitHub Pages for `getBoolean/eikon-source` only when those files are present. Until https://getboolean.github.io/eikon-source/ returns the source page, it is not a Sileo source.
4. After that, push the app tree to https://github.com/getBoolean/eikon. Do not put Theos sources, the IPA, or `.theos` on eikon-source.
