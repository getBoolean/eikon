# Stage 6: Kirikiri and BGI class

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original i386 program presents one Direct3D 9 frame and plays a short wave. That is the graphics and audio class used by Kirikiri and BGI.

**Architecture:** Direct3D 9 goes through DXVK to Vulkan, then MoltenVK to Metal. The guest does not link those libraries. Wine's `d3d9.dll` is pointed at the DXVK build, the way Autorun selects `d3d=dxvk`.

Upstream DXVK requires Vulkan features that MoltenVK does not expose, such as geometry shaders and transform feedback. Task 2 therefore checks the features before building. It uses the macOS-oriented DXVK fork (Gcenx's `dxvk-macOS`) when upstream cannot run on MoltenVK, and records why.

Audio goes through Wine's own `winecoreaudio.drv`, built for iOS. Core Audio's AudioUnit output exists on iOS. Only the parts that are macOS-only (device enumeration through `AudioObject`) get an override that reports one fixed output device, backed by `AVAudioSession`.

The i386 gate from stage 2 still applies. If stage 4 logged `console=blocked-<reason>`, this stage stops at its desktop oracle. This original guest does not need a fixed base, but real Kirikiri and BGI programs may; note that in the stage result.

**Tech Stack:** DXVK (upstream or `dxvk-macOS`), MoltenVK, Core Audio, Wine `d3d9` and `winecoreaudio.drv`, FEX `libwow64fex.dll`.

## Global Constraints

- Acceptance guest is `demos/windows/present`. It is original. No outside program is bundled or required for the pass.
- Kirikiri `.xp3` files and BGI archives are ordinary files. Stage 4 already covers reading them. This stage does not special-case archive formats.
- A `.tpm` plugin is a DLL loaded by the guest. `LoadLibrary` of a DLL beside the exe is in this stage. Plugin behavior beyond loading is not.
- No program titles.
- No JIT bypass.

---

### Task 1: Present guest

**Files:**
- Create: `demos/windows/present/main.c`
- Create: `demos/windows/present/make_tone.py`
- Create: `demos/windows/present/tone.wav`
- Test: `tests/test_present_guest.py`

**Interfaces:**
- Consumes: stages 4 and 5
- Produces: `IDirect3D9`, a device, a clear to green (`0x0000FF00`), `Present`, then exit 0. It also plays `tone.wav` via `PlaySoundA` and returns non-zero if either call fails.

- [ ] **Step 1: Write the failing test**

```python
import struct
from pathlib import Path

DIR = Path(__file__).resolve().parents[1] / "demos" / "windows" / "present"

def test_present_contract():
    text = (DIR / "main.c").read_text(encoding="utf-8")
    assert "D3DCOLOR_XRGB(0, 255, 0)" in text
    assert "PlaySoundA" in text
    assert "present.txt" in text

def test_tone_is_quarter_second_440hz_mono_pcm16():
    data = (DIR / "tone.wav").read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE"
    fmt, channels, rate = struct.unpack_from("<HHI", data, 20)
    bits = struct.unpack_from("<H", data, 34)[0]
    assert (fmt, channels, bits) == (1, 1, 16)
    size = struct.unpack_from("<I", data, 40)[0]
    assert size == rate // 4 * 2
```

Run: `python -m pytest tests/test_present_guest.py -v`

Expected: FAIL

- [ ] **Step 2: Write `main.c`**

Create the device on the stage 5 window. `Clear` the target to `D3DCOLOR_XRGB(0, 255, 0)`. `Present`. `PlaySoundA("tone.wav", NULL, SND_FILENAME | SND_SYNC)`. Write `presented` to `present.txt` only after both succeed.

`tone.wav` is a generated 440 Hz 16-bit mono PCM of 0.25 seconds. Generate it with a Python script `demos/windows/present/make_tone.py` so the bytes are reproducible. The sample rate is 44100, and the script writes a plain 44-byte header with no extra chunks, so the test's offsets hold. Commit the wav.

Run: `python -m pytest tests/test_present_guest.py -v`

Expected: PASS

- [ ] **Step 3: Oracle**

Run under desktop Wine with DXVK's `d3d9.dll` beside the exe. Expected: `present.txt` contains `presented`.

- [ ] **Step 4: Commit**

```bash
git add demos/windows/present tests/test_present_guest.py
git commit -m "Add the Direct3D 9 and wave guest."
```

### Task 2: MoltenVK surface

**Files:**
- Create: `src/host/eikon_vulkan.m`
- Create: `docs/build-dxvk.md`
- Create: `src/host/coreaudio_darwin.c` (override for the macOS-only parts of `winecoreaudio.drv`)

**Interfaces:**
- Consumes: `eikon_window_present` is no longer the Direct3D path. GDI from stage 5 still uses it.
- Produces: a `VkSurfaceKHR` backed by the shell's `CAMetalLayer`

- [ ] **Step 1: Check MoltenVK against DXVK, then document the build**

On the device, or on a Mac with the same MoltenVK version, run `vulkaninfo` against MoltenVK. Compare its output with the required-feature list in the chosen DXVK tag's `src/dxvk/dxvk_adapter.cpp`, and write the missing features into `docs/build-dxvk.md`. If upstream DXVK needs a feature MoltenVK lacks, use `dxvk-macOS` and record which one decided it.

`docs/build-dxvk.md` records a 32-bit `d3d9.dll`, the source repo and the pinned tag (written in when the build is first done), and the MoltenVK version. The DLL is copied to the guest root as `d3d9.dll`.

- [ ] **Step 2: Create the Metal layer and the Vulkan surface**

`eikon_vulkan.m` exposes `eikon_metal_layer` for MoltenVK. The Darwin winevulkan driver creates the surface from that layer. Frames are presented by MoltenVK. The stage 5 bitmap path remains for GDI guests.

The guest runs in `eikon-wine`, not in the app, so the layer cannot be handed over as a pointer. Either the Metal layer and MoltenVK live in `eikon-wine` and the app shows them through a `CALayerHost`-style remote layer context, or frames cross over through an `IOSurface` shared with the app. Pick one, and record the choice and the reason in `docs/build-dxvk.md`.

- [ ] **Step 3: Device acceptance**

Button `Run present`. Probe log gains `present=0`. The view is green for the length of the wave. `present.txt` contains `presented`.

- [ ] **Step 4: Commit**

```bash
git add src/host/eikon_vulkan.m src/host/coreaudio_darwin.c docs/build-dxvk.md Makefile
git commit -m "Present Direct3D 9 through MoltenVK and play a wave."
```

### Task 3: Load a sibling DLL

**Files:**
- Create: `demos/windows/present/plugin.c`
- Modify: `demos/windows/present/main.c`

**Interfaces:**
- Consumes: `LoadLibraryA` / `GetProcAddress` on the Darwin loader
- Produces: `plugin.dll` exporting `plugin_ok` which returns 1. The guest loads it from its own directory and fails if the return is not 1.

- [ ] **Step 1: Implement and run**

This is the `.tpm` loading case: a DLL next to the executable, not a system DLL. System DLLs stay on Wine's builtin list.

Build with `i686-w64-mingw32-gcc -shared -o plugin.dll plugin.c`. After `plugin_ok()` returns 1, the guest writes `plugin=1` as a second line of `present.txt`. The app copies that line into the probe log. Add `assert "plugin_ok" in text` to `test_present_contract`.

Expected device log: `present=0` still, and `plugin=1`.

- [ ] **Step 2: Commit**

```bash
git add demos/windows/present tests/test_present_guest.py
git commit -m "Load a sibling DLL from the present guest."
```
