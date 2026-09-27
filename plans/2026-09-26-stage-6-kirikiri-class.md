# Stage 6: Kirikiri and BGI class

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original i386 program presents one Direct3D 9 frame and plays a short wave. That is the graphics and audio class used by Kirikiri and BGI.

**Architecture:** Direct3D 9 goes through DXVK to Vulkan, then MoltenVK to Metal. Audio goes through a small `audiodrv` that plays PCM on `AVAudioEngine`. The guest does not link those libraries; Wine's `d3d9.dll` is pointed at the DXVK build the way Autorun selects `d3d=dxvk`. If stage 2 logged `low4g_page=fail`, record that in the stage result. Guests that need a fixed base below 4 GB stay blocked. This original guest does not need a fixed base.

**Tech Stack:** DXVK, MoltenVK, AVFoundation, Wine `d3d9`, Box64 wowbox64.

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
- Test: `tests/test_present_guest.py`

**Interfaces:**
- Consumes: stages 4 and 5
- Produces: `IDirect3D9`, a device, a clear to green (`0x0000FF00`), `Present`, then exit 0. It also plays `tone.wav` via `PlaySoundA` and returns non-zero if either call fails.

- [ ] **Step 1: Write `main.c`**

Create the device on the stage 5 window. `Clear` the target to `D3DCOLOR_XRGB(0, 255, 0)`. `Present`. `PlaySoundA("tone.wav", NULL, SND_FILENAME | SND_SYNC)`. Write `presented` to `present.txt` only after both succeed.

`tone.wav` is a generated 440 Hz 16-bit mono PCM of 0.25 seconds. Generate it with a Python script `demos/windows/present/make_tone.py` so the bytes are reproducible. Commit the wav.

- [ ] **Step 2: Oracle**

Run under desktop Wine with DXVK's `d3d9.dll` beside the exe. Expected: `present.txt` contains `presented`.

- [ ] **Step 3: Commit**

```bash
git add demos/windows/present tests/test_present_guest.py
git commit -m "Add the Direct3D 9 and wave guest."
```

### Task 2: MoltenVK surface

**Files:**
- Create: `src/host/eikon_vulkan.m`
- Create: `docs/build-dxvk.md`

**Interfaces:**
- Consumes: `eikon_window_present` is no longer the Direct3D path. GDI from stage 5 still uses it.
- Produces: a `VkSurfaceKHR` backed by the shell's `CAMetalLayer`

- [ ] **Step 1: Document the DXVK build**

`docs/build-dxvk.md` records a 32-bit `d3d9.dll` built from DXVK at a pinned release tag, written into the doc when the build is first done. The DLL is copied to the guest root as `d3d9.dll`.

- [ ] **Step 2: Create the Metal layer and the Vulkan surface**

`eikon_vulkan.m` exposes `eikon_metal_layer` for MoltenVK. The Darwin winevulkan driver creates the surface from that layer. Frames are presented by MoltenVK. The stage 5 bitmap path remains for GDI guests.

- [ ] **Step 3: Device acceptance**

Button `Run present`. Probe log gains `present=0`. The view is green for the length of the wave. `present.txt` contains `presented`.

- [ ] **Step 4: Commit**

```bash
git add src/host/eikon_vulkan.m docs/build-dxvk.md Makefile
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

Expected device log: `present=0` still, and `plugin=1`.

- [ ] **Step 2: Commit**

```bash
git add demos/windows/present
git commit -m "Load a sibling DLL from the present guest."
```
