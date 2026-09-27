# Stage 11: Kirikiri without emulation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original Kirikiri script, packed in an `.xp3` archive, runs on the device through an iOS port of Kirikiroid2. It shows an image and a line of Japanese text, takes a tap, plays a sound, and writes a result file. Kirikiroid2 and every project it draws on are credited in the app, the deb, and the repo.

**Architecture:** Kirikiroid2 (https://github.com/zeas2/Kirikiroid2, by zeas2 and contributors) is an Android port of the Kirikiri engine, built mostly from Kirikiri 2 and KirikiriZ code. It interprets TJS2 and generates no machine code, so it needs no JIT, no low 4 GB, no x18, and no Wine. Eikon ports its Android-specific parts (app shell, storage, audio, video, and input) to iOS and runs it in the app process, or in a helper if Task 4 finds that simpler.

This route is separate from the Wine route (stages 4 to 6), and both stay. The Wine route covers BGI and any Kirikiri game this route cannot open.

Known limits:

- **`.tpm` plugins are x86 Windows DLLs.** They cannot load here. A game that needs one runs only if Kirikiroid2 has a native replacement for that plugin. In the collection, 3 of the 21 Kirikiri folders have a `.tpm`.
- **Encrypted archives.** Many commercial `.xp3` files are encrypted, usually by a `.tpm`. Record what Kirikiroid2 supports. Do not add per-title keys to this repo.

**Licensing.** Kirikiroid2's `LICENSE` is a BSD-style license (from KirikiriZ), followed by licenses for bundled libraries: libjpeg-turbo, libpng, zlib, Oniguruma, FreeType, picojson, MT19937, an Apache 2.0 component, and the Xiph.org libraries (Ogg, Vorbis, Theora). Its README also names code adapted from projects under other licenses:
- Kodi, for the video player. Kodi is GPL-2.0-or-later.
- glibc and Apple Libc, for string code.
- etcpak, pvrtccompressor, and astcrt, for texture codecs.
- AmazeFileManager, for Android storage. AmazeFileManager is GPL-3.0.

GPL code in the app binary would put the whole app under the GPL. Task 1 audits every file before anything ships.

**Tech Stack:** Kirikiroid2 at a pinned commit, its bundled libraries, CMake or its own build, UIKit, Metal or OpenGL ES as its renderer allows, Core Audio, Theos.

## Global Constraints

- Keep every upstream copyright header and license notice. Do not remove or reword them, including in patched files.
- Nothing ships until the Task 1 audit has an action for every component.
- Test content is original and lives in `demos/kirikiri/`. No outside game data is bundled or required for the pass.
- No program titles, and no per-title decryption keys.
- Kirikiroid2 is the submodule `third_party/Kirikiroid2`, pinned to a commit. Changes live in `patches/kirikiroid2/`, applied to a copy under `build/`, the same rule as FEX in stage 3.
- No JIT of any kind in this stage.

---

### Task 1: Pin, audit, and credit

**Files:**
- Create: `third_party/Kirikiroid2` (submodule)
- Create: `docs/kirikiroid2-license-audit.md`
- Modify: `THIRD_PARTY_NOTICES.md`, `Resources/licenses/`, `Resources/en.lproj/Localizable.strings` (created in stage 1 Task 4)

**Interfaces:**
- Consumes: stage 1 Task 4's attribution setup
- Produces: an audit with one row per component, and Kirikiroid2's entries in every place credits appear

- [ ] **Step 1: Pin**

```bash
git submodule add https://github.com/zeas2/Kirikiroid2 third_party/Kirikiroid2
git -C third_party/Kirikiroid2 rev-parse HEAD
```

Record the commit and its date in `docs/kirikiroid2-license-audit.md`.

- [ ] **Step 2: Audit**

For each directory and each derived-code origin the README names, record in a table:
- the component
- its license, from the file headers, not only the top-level `LICENSE`
- the copyright holders
- whether the iOS build needs it
- the action: `ship`, `exclude`, or `replace with <what>`

Default actions:
- **AmazeFileManager storage code** is Android-only: `exclude`.
- **Kodi-derived video code:** `exclude` at first, and replace with an AVFoundation-based player behind the same interface. Shipping it is the owner's call, because it makes the app GPL.
- **glibc-derived string code:** `replace with` the iOS C library's functions, if the headers show LGPL. Static LGPL code in an iOS app carries relinking obligations.
- **Apple Libc code:** `ship` with its APSL notice, or `replace` like glibc.
- **The texture codecs:** record each license. Keep only what the iOS renderer needs.

If any row cannot be resolved, stop and report to the owner.

- [ ] **Step 3: Credit**

- `THIRD_PARTY_NOTICES.md` gets a Kirikiroid2 section, credited to zeas2 and contributors, with the repo URL and pinned commit. It also credits the Kirikiri 2 and KirikiriZ authors as the upstream engine, and lists every shipped component from the audit with its license.
- `Resources/licenses/` gets the full license text for each shipped component, copied verbatim. Kirikiroid2's `LICENSE` goes in as `Kirikiroid2-LICENSE.txt`.
- The in-app Acknowledgements screen, from stage 1 Task 4, lists the same entries and shows each full text.
- The README's Credits section names Kirikiroid2 with a link.

Run: `python3 -m pytest tests/test_third_party_notices.py -v`

Expected: PASS, with `third_party/Kirikiroid2` covered.

- [ ] **Step 4: Commit**

```bash
git add .gitmodules third_party/Kirikiroid2 docs/kirikiroid2-license-audit.md THIRD_PARTY_NOTICES.md Resources/licenses README.md
git commit -m "Pin Kirikiroid2, audit its licenses, and credit it."
```

### Task 2: The test script

**Files:**
- Create: `demos/kirikiri/data/startup.tjs`
- Create: `demos/kirikiri/data/bg.png`
- Create: `demos/kirikiri/data/tone.ogg`
- Create: `demos/kirikiri/make_assets.py`
- Create: `demos/kirikiri/pack.py`
- Test: `tests/test_kirikiri_demo.py`

**Interfaces:**
- Consumes: nothing
- Produces: `demos/kirikiri/data/` and a packed `demos/kirikiri/data.xp3`. The script opens a 640 by 480 window, draws `bg.png`, and draws the line `こんにちは、世界。` with `Layer.drawText`. It plays `tone.ogg`. On the first click it writes `clicked` to `result.txt` in the save folder and exits.

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "demos" / "kirikiri"

def test_script_contract():
    text = (ROOT / "data" / "startup.tjs").read_text(encoding="utf-8-sig")
    assert "drawText" in text
    assert "こんにちは、世界。" in text
    assert "result.txt" in text

def test_archive_starts_with_xp3_magic():
    assert (ROOT / "data.xp3").read_bytes()[:11] == b"XP3\r\n \n\x1a\x8b\x67\x01"
```

Run: `python3 -m pytest tests/test_kirikiri_demo.py -v`

Expected: FAIL

- [ ] **Step 2: Write the script, assets, and packer**

`make_assets.py` generates `bg.png` (a flat colour) and `tone.ogg` (440 Hz, 0.25 seconds), so both are reproducible. `pack.py` writes an unencrypted XP3 archive from `data/`.

Save `startup.tjs` as UTF-8 with a BOM. Kirikiri reads that as Unicode; without the BOM it would read the file as Shift-JIS.

Run: `python3 -m pytest tests/test_kirikiri_demo.py -v`

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add demos/kirikiri tests/test_kirikiri_demo.py
git commit -m "Add the original Kirikiri test script and archive."
```

### Task 3: Map the port

**Files:**
- Create: `docs/build-kirikiri.md`

**Interfaces:**
- Consumes: Tasks 1 and 2
- Produces: the list of Android-specific code and what replaces it on iOS

- [ ] **Step 1: Read the tree**

Record in `docs/build-kirikiri.md`:
- the UI and app framework it is built on, and whether that framework has an iOS target
- the renderer: OpenGL ES, or something else. iOS still has OpenGL ES, but it is deprecated; note whether Metal is needed now or later
- the audio and video back ends
- every JNI and Android API use, grouped by area
- the build system, and whether a desktop build (Windows, macOS, or Linux) exists for use as an oracle
- which plugins it reimplements natively, by plugin file name
- which archive encryption it handles, and how

- [ ] **Step 2: Oracle**

If a desktop build exists, run `data/` and then `data.xp3` on it. Expected: the image, the Japanese line with no garbled characters, the tone, and `result.txt` after a click. Otherwise use Kirikiroid2's Android build on an emulator or device as the oracle.

- [ ] **Step 3: Commit**

```bash
git add docs/build-kirikiri.md
git commit -m "Map Kirikiroid2's Android dependencies for the iOS port."
```

### Task 4: iOS port and device run

**Files:**
- Create: `patches/kirikiroid2/`
- Create: `src/kirikiri/` (iOS replacements for the Android layers, and `EikonKirikiriView`)
- Create: `cmake/ios.toolchain.cmake` if stage 3 has not already created it
- Modify: `src/RootViewController.m`, `Makefile`, `docs/build-kirikiri.md`

**Interfaces:**
- Consumes: Tasks 1 to 3
- Produces: a button `Run Kirikiri` that runs `data.xp3` full screen, maps a tap to a left click, and appends `kirikiri=<exit code>` to `probe.log`

- [ ] **Step 1: Build the engine for iOS**

Build it as a static library with the iOS toolchain, leaving out what the audit excluded. New files in `src/kirikiri/` carry Eikon's license header. Files adapted from Kirikiroid2 keep its header and add a line saying what Eikon changed. Record disabled features and patches in `docs/build-kirikiri.md`.

Fonts come from the app bundle. Stage 12 adds the CJK font set; until then, bundle one OFL-licensed Japanese font so the test line renders, and credit it in `THIRD_PARTY_NOTICES.md`.

- [ ] **Step 2: Embed it**

`EikonKirikiriView` hosts the engine's drawing surface and forwards touches. The save folder is `EikonDataURL()/kirikiri/<archive hash>/`, so no title is recorded.

- [ ] **Step 3: Device acceptance**

Expected: the image and the Japanese line are visible, the tone plays, a tap writes `result.txt`, and the log gains `kirikiri=0`. The Acknowledgements screen lists Kirikiroid2.

- [ ] **Step 4: Plugin list**

Scan the collection's `.tpm` files by file name only, then write the names and a count into `docs/build-kirikiri.md`. Mark each as `native` (Kirikiroid2 has a replacement), `missing`, or `encryption`. Record no titles. This list is the backlog for later plugin work.

- [ ] **Step 5: Commit**

```bash
git add patches/kirikiroid2 src/kirikiri cmake docs/build-kirikiri.md src/RootViewController.m Makefile THIRD_PARTY_NOTICES.md Resources
git commit -m "Run an original Kirikiri archive on iOS through Kirikiroid2."
```
